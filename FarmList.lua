-- FarmList: a small farming checklist. Counts what you gather or buy; selling or using items
-- afterwards does not reduce the progress.
-- MIT License, Copyright (c) 2026 Glacier94

local ADDON, ns = ...
local ROW_HEIGHT = 22
local FRAME_WIDTH = 360
local DEFAULT_TARGET = 20

local db           -- FarmListCharDB (per character)
local frame, rows, emptyText, totalText = nil, {}, nil, nil
local ready = false -- snapshots taken after login; gains before that are not counted
local blockers = {} -- open windows during which gains are not counted as farmed
local credit = {}   -- itemID -> amount taken from AH purchase mail; counts even while the mailbox is open
local ignore = {}   -- itemID -> amount bought back at a merchant; was already counted before it was sold

local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

-- Bags + bank (+ reagent bank), so moving items to or from the bank is not a gain
local function Count(itemID)
	if C_Item and C_Item.GetItemCount then
		return C_Item.GetItemCount(itemID, true, false, true) or 0
	end
	return GetItemCount(itemID, true) or 0
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99FarmList|r: " .. msg)
end

local function ItemName(itemID)
	return GetInfo(itemID) or ("Item " .. itemID)
end

-- Lower case, umlauts written out, so "magiestoff", "Magiestoff" and "Wuerzige"/"Würzige" compare
local UMLAUTS = { ["Ä"] = "ae", ["Ö"] = "oe", ["Ü"] = "ue", ["ä"] = "ae", ["ö"] = "oe", ["ü"] = "ue", ["ß"] = "ss" }
local function Normalize(text)
	text = text:gsub("\195[\128-\191]", UMLAUTS) -- two-byte UTF-8 letters; unmapped ones stay as they are
	text = text:lower():gsub("[%s%-']+", " ")
	return strtrim(text)
end

-- Client-language names of the built-in materials, cached across sessions
local function MaterialName(itemID)
	local name = GetInfo(itemID)
	if name then
		FarmListDB.names[itemID] = name
		return name
	end
	return FarmListDB.names[itemID]
end

local function LoadMaterialNames()
	if FarmListDB.namesLocale ~= GetLocale() then
		FarmListDB.names = {}
		FarmListDB.namesLocale = GetLocale()
	end
	for itemID in pairs(ns.MATERIALS) do
		if not MaterialName(itemID) and C_Item and C_Item.RequestLoadItemDataByID then
			C_Item.RequestLoadItemDataByID(itemID) -- answer arrives as GET_ITEM_INFO_RECEIVED
		end
	end
end

-- Finds an item by name among the built-in materials and the current list.
-- Exact match first, then names starting with the text, then names containing it.
-- Returns the item ID, or nil plus a list of candidate names if the text is ambiguous.
local function FindByName(text)
	local query = Normalize(text)
	if query == "" then return nil end
	local candidates = {}
	local function Consider(itemID, name)
		if name then candidates[itemID] = candidates[itemID] or {}; table.insert(candidates[itemID], Normalize(name)) end
	end
	for itemID, english in pairs(ns.MATERIALS) do
		Consider(itemID, MaterialName(itemID))
		Consider(itemID, english)
	end
	for _, list in ipairs({ db.items, FarmListDB.items }) do
		for _, entry in ipairs(list) do Consider(entry.id, GetInfo(entry.id)) end
	end
	for _, test in ipairs({
		function(n) return n == query end,
		function(n) return n:sub(1, #query) == query end,
		function(n) return n:find(query, 1, true) ~= nil end,
	}) do
		local hits = {}
		for itemID, names in pairs(candidates) do
			for _, n in ipairs(names) do
				if test(n) then table.insert(hits, itemID); break end
			end
		end
		if #hits == 1 then return hits[1] end
		if #hits > 1 then
			local shown = {}
			for _, itemID in ipairs(hits) do table.insert(shown, MaterialName(itemID) or ns.MATERIALS[itemID] or ItemName(itemID)) end
			table.sort(shown)
			return nil, shown
		end
	end
end

-- Item link, item ID, or name (built-in materials, current list, or anything the client knows).
-- Second return value: candidate names if the name is ambiguous.
local function ItemIDFrom(text)
	if not text or text == "" then return nil end
	local id = text:match("item:(%d+)") or text:match("^(%d+)$")
	if id then return tonumber(id) end
	local found, ambiguous = FindByName(text)
	if found or ambiguous then return found, ambiguous end
	local link = select(2, GetInfo(text))
	return link and tonumber(link:match("item:(%d+)")) or nil
end

local function ReportNotFound(text, ambiguous)
	if ambiguous then
		local max = 12
		local list = table.concat(ambiguous, ", ", 1, math.min(#ambiguous, max))
		if #ambiguous > max then list = list .. ", … (" .. #ambiguous .. " Treffer)" end
		Print("\"" .. text .. "\" ist nicht eindeutig: " .. list)
	else
		Print("Item \"" .. text .. "\" nicht gefunden. Name, Item-ID oder Shift-Klick-Link verwenden. Hilfe: /farm help")
	end
end

-- Per-character list by default; "/farm global" switches to one list shared by all characters
local function List()
	return db.useGlobal and FarmListDB.items or db.items
end

local function FindEntry(itemID)
	for i, entry in ipairs(List()) do
		if entry.id == itemID then return entry, i end
	end
end

local function Price(itemID)
	if not TSM_API or not TSM_API.GetCustomPriceValue then return nil end
	local ok, value = pcall(TSM_API.GetCustomPriceValue, db.priceSource, "i:" .. itemID)
	return ok and value or nil
end

local function Money(copper)
	if TSM_API and TSM_API.FormatMoneyString then
		local ok, str = pcall(TSM_API.FormatMoneyString, copper)
		if ok then return str end
	end
	return GetCoinTextureString(copper)
end

local function PlayDone()
	pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE) or 878)
end

-- ============================================================================
-- Progress tracking
-- ============================================================================

-- Snapshot of the current count, per character (independent of which list is active)
local function Snapshot(itemID)
	db.snap[itemID] = Count(itemID)
end

local function SnapshotAll()
	for _, entry in ipairs(List()) do Snapshot(entry.id) end
end

local function IsBlocked()
	return next(blockers) ~= nil
end

local function AddProgress(entry, amount)
	local wasDone = entry.collected >= entry.target
	entry.collected = math.max(0, entry.collected + amount)
	if not wasDone and entry.collected >= entry.target then
		Print(ItemName(entry.id) .. " fertig! (" .. entry.collected .. " / " .. entry.target .. ")")
		PlayDone()
	end
end

-- Takes up to `amount` from a pending table entry, returns how much was taken
local function Take(pending, itemID, amount)
	local have = pending[itemID]
	if not have then return 0 end
	local taken = math.min(have, amount)
	pending[itemID] = (have > taken) and (have - taken) or nil
	return taken
end

-- Only increases count as farmed; decreases (sold, crafted, destroyed) are ignored.
-- Bought items count (merchant, AH); AH purchases arrive by mail and count via `credit`.
local function ScanGains()
	if not ready then return end
	local blocked = IsBlocked()
	for _, entry in ipairs(List()) do
		local now = Count(entry.id)
		local before = db.snap[entry.id]
		if before and now > before then
			local gain = now - before
			gain = gain - Take(ignore, entry.id, gain)
			if blocked then gain = Take(credit, entry.id, gain) end
			if gain > 0 then AddProgress(entry, gain) end
		end
		db.snap[entry.id] = now
	end
end

-- AH purchase mails ("buyer" invoices): their attachments count as bought, not as mail
local function CreditMail(index, attachment)
	if not GetInboxInvoiceInfo or GetInboxInvoiceInfo(index) ~= "buyer" then return end
	local first, last = attachment or 1, attachment or (ATTACHMENTS_MAX_RECEIVE or 16)
	for i = first, last do
		local _, itemID, _, count = GetInboxItem(index, i)
		if not itemID then
			local link = GetInboxItemLink and GetInboxItemLink(index, i)
			itemID = link and tonumber(link:match("item:(%d+)"))
		end
		if itemID and count and count > 0 then credit[itemID] = (credit[itemID] or 0) + count end
	end
end

local function HookPurchases()
	-- Hooked after TSM (OptionalDeps), so TSM's own mail opening goes through these too
	if TakeInboxItem then hooksecurefunc("TakeInboxItem", function(index, attachment) CreditMail(index, attachment) end) end
	if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", function(index) CreditMail(index) end) end
	if BuybackItem then
		hooksecurefunc("BuybackItem", function(slot)
			local link = GetBuybackItemLink and GetBuybackItemLink(slot)
			local itemID = link and tonumber(link:match("item:(%d+)"))
			local quantity = select(4, GetBuybackItemInfo(slot)) or 1
			if itemID then ignore[itemID] = (ignore[itemID] or 0) + quantity end
		end)
	end
end

-- ============================================================================
-- UI
-- ============================================================================

local function SavePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	db.point = { point, relPoint, x, y }
end

local function CreateRow(index)
	local row = CreateFrame("Button", nil, frame)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 8, -26 - (index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", -8, -26 - (index - 1) * ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:EnableMouseWheel(db.wheel)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
	row.icon:SetPoint("LEFT", 0, 0)

	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 4, 0)
	row.bar:SetPoint("BOTTOMRIGHT", 0, 2)
	row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.bar:SetMinMaxValues(0, 1)
	row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
	row.bar.bg:SetAllPoints()
	row.bar.bg:SetColorTexture(0, 0, 0, 0.5)

	row.name = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 4, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.count = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.count:SetPoint("RIGHT", -4, 0)
	row.count:SetJustifyH("RIGHT")
	row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)

	row:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetItemByID(self.itemID)
		local price = Price(self.itemID)
		if price then
			GameTooltip:AddDoubleLine("FarmList AH-Preis/Stück:", Money(price), 0.6, 0.8, 1, 1, 1, 1)
		end
		GameTooltip:AddLine(" ")
		if db.wheel then
			GameTooltip:AddLine("Mausrad: Ziel ±1 (Shift: ±10)", 0.6, 0.8, 1)
			GameTooltip:AddLine("Strg + Mausrad: Fortschritt ±1 (Shift: ±10)", 0.6, 0.8, 1)
		else
			GameTooltip:AddLine("Mausrad gesperrt (Haken \"Mausrad\" oben setzen)", 0.6, 0.6, 0.6)
		end
		GameTooltip:AddLine("Rechtsklick: entfernen", 0.6, 0.8, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnMouseWheel", function(self, delta)
		local entry = FindEntry(self.itemID)
		if not entry or not db.wheel then return end
		local step = delta * (IsShiftKeyDown() and 10 or 1)
		if IsControlKeyDown() then
			entry.collected = math.max(0, entry.collected + step)
		else
			entry.target = math.max(1, entry.target + step)
		end
		FarmList_Update()
	end)
	row:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			local _, i = FindEntry(self.itemID)
			if i then table.remove(List(), i) end
			FarmList_Update()
		elseif IsModifiedClick("CHATLINK") then
			local link = select(2, GetInfo(self.itemID))
			if link then ChatEdit_InsertLink(link) end
		end
	end)
	rows[index] = row
	return row
end

-- Unlocked rows catch the mouse wheel; locked rows pass it on (camera zoom keeps working)
local function SetWheel(enabled)
	db.wheel = enabled
	for _, row in ipairs(rows) do row:EnableMouseWheel(enabled) end
end

local function AddFromCursor()
	local kind, itemID = GetCursorInfo()
	if kind == "item" and itemID then
		ClearCursor()
		FarmList_Add(itemID, DEFAULT_TARGET)
	end
end

local function CreateMainFrame()
	frame = CreateFrame("Frame", "FarmListFrame", UIParent, "BackdropTemplate")
	frame:SetWidth(FRAME_WIDTH)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.75)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)
	frame:SetScript("OnReceiveDrag", AddFromCursor)
	frame:SetScript("OnMouseUp", function() if GetCursorInfo() then AddFromCursor() end end)

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", 10, -8)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() FarmList_Toggle(false) end)

	-- Mouse wheel editing is off unless ticked, so scrolling over the list changes nothing by accident
	local wheel = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	wheel:SetSize(20, 20)
	wheel:SetPoint("RIGHT", close, "LEFT", -46, 0)
	wheel:SetChecked(db.wheel)
	wheel.label = wheel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	wheel.label:SetPoint("LEFT", wheel, "RIGHT", 0, 1)
	wheel.label:SetText("Mausrad")
	wheel:SetHitRectInsets(0, -46, 0, 0) -- label is clickable too
	wheel:SetScript("OnClick", function(self) SetWheel(self:GetChecked() and true or false) end)
	wheel:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Mausrad-Bearbeitung")
		GameTooltip:AddLine("An: Mausrad ändert Ziel, Strg + Mausrad den Fortschritt.", 1, 1, 1, true)
		GameTooltip:AddLine("Aus: Scrollen über der Liste ändert nichts.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	wheel:SetScript("OnLeave", GameTooltip_Hide)
	frame.wheel = wheel

	emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	emptyText:SetPoint("TOPLEFT", 10, -30)
	emptyText:SetPoint("RIGHT", -10, 0)
	emptyText:SetJustifyH("LEFT")
	emptyText:SetText("Item hierher ziehen oder\n/farm add [Item] 20")

	totalText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	totalText:SetPoint("BOTTOMRIGHT", -10, 8)
	totalText:SetJustifyH("RIGHT")

	if db.point then
		frame:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 120)
	end
end

function FarmList_Update()
	if not frame then return end
	local items = List()
	local totalCost, hasPrice = 0, false
	for i, entry in ipairs(items) do
		local row = rows[i] or CreateRow(i)
		row.itemID = entry.id
		row.icon:SetTexture(GetIcon(entry.id))
		row.name:SetText(ItemName(entry.id))
		local left = entry.target - entry.collected
		local price = Price(entry.id)
		if price then hasPrice = true end
		if left > 0 then
			local cost = ""
			if price then
				totalCost = totalCost + price * left
				cost = "  |cffaaaaaa" .. Money(price * left) .. "|r"
			end
			row.count:SetText(string.format("%d / %d  |cffffd100noch %d|r%s", entry.collected, entry.target, left, cost))
			row.bar:SetStatusBarColor(0.2, 0.45, 0.8)
		else
			row.count:SetText(string.format("|cff33ff33%d / %d  fertig|r", entry.collected, entry.target))
			row.bar:SetStatusBarColor(0.1, 0.6, 0.1)
		end
		row.bar:SetValue(math.min(entry.collected / entry.target, 1))
		row:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	emptyText:SetShown(#items == 0)
	frame.title:SetText(db.useGlobal and "Farmliste |cffaaaaaa(alle Chars)|r" or "Farmliste")
	local footer = hasPrice and 18 or 4
	totalText:SetText(hasPrice and ("Rest im AH: " .. Money(totalCost)) or "")
	frame:SetHeight(30 + math.max(#items, 2) * ROW_HEIGHT + footer)
end

function FarmList_Toggle(show)
	if show == nil then show = not frame:IsShown() end
	db.shown = show
	frame:SetShown(show)
	if show then FarmList_Update() end
end

function FarmList_Add(itemID, target)
	local entry = FindEntry(itemID)
	if entry then
		entry.target = target
	else
		table.insert(List(), { id = itemID, target = target, collected = 0 })
	end
	-- Progress starts now: what is already in bags/bank does not count
	Snapshot(itemID)
	-- Item info may not be cached yet; refresh once it arrives
	if Item and Item.CreateFromItemID then
		Item:CreateFromItemID(itemID):ContinueOnItemLoad(FarmList_Update)
	end
	FarmList_Toggle(true)
end

-- ============================================================================
-- Slash command
-- ============================================================================

local HELP = {
	"/farm  - Fenster an/aus",
	"/farm [Item] [Anzahl]  - Kurzform von add, z.B. /farm magiestoff 200",
	"/farm add [Item] [Anzahl]  - Item (Name, Link oder ID) hinzufügen/Ziel setzen",
	"/farm set [Item] [Anzahl]  - Fortschritt von Hand setzen (z.B. schon vorhandene)",
	"/farm reset [Item]  - Fortschritt auf 0 (ohne Item: alle)",
	"/farm remove [Item]  - Item entfernen",
	"/farm clear  - Liste leeren",
	"/farm global  - eigene Liste / gemeinsame Liste aller Charaktere umschalten",
	"/farm price [Quelle]  - TSM-Preis für die AH-Kosten (Standard: first(dbminbuyout, dbmarket))",
	"Gezählt wird nur, was neu dazukommt. Verkaufen/Verbrauchen zieht nichts ab.",
	"Gekauftes zählt (Händler, Auktionshaus, auch AH-Käufe aus der Post).",
	"Nicht gezählt: sonstige Post, Handel, Bank, Rückkauf beim Händler.",
	"Tipp: Item ins Fenster ziehen, Rechtsklick = entfernen. Mit Haken \"Mausrad\": Mausrad = Ziel, Strg+Mausrad = Fortschritt.",
}

local function SplitItemAndNumber(rest)
	local number = tonumber(rest:match("(%d+)%s*$"))
	local itemPart = number and rest:gsub("%s*%d+%s*$", "") or rest
	-- "/farm add 2589" (only an item ID, no amount)
	if number and itemPart == "" then return rest, nil end
	return itemPart, number
end

SLASH_FARMLIST1 = "/farm"
SLASH_FARMLIST2 = "/farmlist"
SlashCmdList.FARMLIST = function(msg)
	msg = strtrim(msg or "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "" then
		FarmList_Toggle()
	elseif cmd == "add" or cmd == "set" then
		local itemPart, number = SplitItemAndNumber(rest)
		local itemID, ambiguous = ItemIDFrom(itemPart)
		if not itemID then return ReportNotFound(itemPart, ambiguous) end
		if cmd == "add" then
			FarmList_Add(itemID, number or DEFAULT_TARGET)
		else
			local entry = FindEntry(itemID)
			if not entry then
				FarmList_Add(itemID, DEFAULT_TARGET)
				entry = FindEntry(itemID)
			end
			entry.collected = number or 0
			FarmList_Update()
		end
	elseif cmd == "reset" then
		local itemID, ambiguous = ItemIDFrom(rest)
		if rest ~= "" and not itemID then return ReportNotFound(rest, ambiguous) end
		for _, entry in ipairs(List()) do
			if not itemID or entry.id == itemID then entry.collected = 0 end
		end
		SnapshotAll()
		FarmList_Update()
	elseif cmd == "remove" or cmd == "del" then
		local itemID, ambiguous = ItemIDFrom(rest)
		if not itemID then return ReportNotFound(rest, ambiguous) end
		local _, i = FindEntry(itemID)
		if i then table.remove(List(), i) end
		FarmList_Update()
	elseif cmd == "clear" then
		wipe(List())
		FarmList_Update()
	elseif cmd == "global" then
		db.useGlobal = not db.useGlobal
		SnapshotAll()
		Print(db.useGlobal and "Gemeinsame Liste (alle Charaktere)" or "Eigene Liste (nur dieser Charakter)")
		FarmList_Update()
	elseif cmd == "price" then
		if rest ~= "" then db.priceSource = rest end
		Print("Preisquelle: " .. db.priceSource)
		FarmList_Update()
	elseif cmd == "help" or cmd == "hilfe" or cmd == "?" then
		for _, line in ipairs(HELP) do Print(line) end
	else
		-- "/farm magiestoff 200" is short for "/farm add magiestoff 200"
		local itemPart, number = SplitItemAndNumber(msg)
		local itemID, ambiguous = ItemIDFrom(itemPart)
		if not itemID then return ReportNotFound(itemPart, ambiguous) end
		FarmList_Add(itemID, number or DEFAULT_TARGET)
	end
end

-- ============================================================================
-- Events
-- ============================================================================

-- While one of these windows is open, new items are not farmed (mail, trade, bank).
-- Exception: attachments of AH purchase mails (see CreditMail).
local BLOCK_EVENTS = {
	MAIL_SHOW = "mail",
	TRADE_SHOW = "trade",
	BANKFRAME_OPENED = "bank",
	GUILDBANKFRAME_OPENED = "guildbank",
}
local BLOCK_CLOSE = {
	MAIL_CLOSED = "mail", TRADE_CLOSED = "trade", BANKFRAME_CLOSED = "bank", GUILDBANKFRAME_CLOSED = "guildbank",
}

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		FarmListDB = FarmListDB or {}
		FarmListDB.items = FarmListDB.items or {}
		FarmListDB.names = FarmListDB.names or {}
		FarmListCharDB = FarmListCharDB or {}
		db = FarmListCharDB
		db.items = db.items or {}
		db.snap = db.snap or {}
		db.priceSource = db.priceSource or "first(dbminbuyout, dbmarket)"
		if db.shown == nil then db.shown = true end
		db.wheel = db.wheel == true -- mouse wheel editing is off by default
		-- Migrate entries from version 1.0 (no progress counter yet)
		for _, list in ipairs({ db.items, FarmListDB.items }) do
			for _, entry in ipairs(list) do entry.collected = entry.collected or 0 end
		end
		CreateMainFrame()
		frame:SetShown(db.shown)
		LoadMaterialNames()
		self:UnregisterEvent("ADDON_LOADED")
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("BAG_UPDATE_DELAYED")
		self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		for _, list in ipairs({ BLOCK_EVENTS, BLOCK_CLOSE }) do
			for name in pairs(list) do
				pcall(self.RegisterEvent, self, name) -- not every event exists in every client
			end
		end
		pcall(self.RegisterEvent, self, "MERCHANT_CLOSED")
		HookPurchases()
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Fresh snapshot at login/zone change; anything gained while offline does not count
		SnapshotAll()
		ready = true
		FarmList_Update()
	elseif BLOCK_EVENTS[event] then
		ScanGains() -- count anything farmed right before opening the window
		blockers[BLOCK_EVENTS[event]] = true
	elseif BLOCK_CLOSE[event] then
		ScanGains() -- AH purchases taken from the mail whose bag update is still pending
		blockers[BLOCK_CLOSE[event]] = nil
		if event == "MAIL_CLOSED" then wipe(credit) end
		SnapshotAll() -- items received through the window are not farmed
	elseif event == "MERCHANT_CLOSED" then
		ScanGains()
		wipe(ignore) -- a buyback that failed (no money, bags full) must not swallow later gains
	elseif event == "BAG_UPDATE_DELAYED" then
		ScanGains()
		if frame:IsShown() then FarmList_Update() end
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if ns.MATERIALS[arg1] then MaterialName(arg1) end
		if frame:IsShown() then FarmList_Update() end
	end
end)
