-- FarmList: a small farming checklist. Counts what you gather; selling or using items
-- afterwards does not reduce the progress.
-- MIT License, Copyright (c) 2026 Glacier94

local ADDON = ...
local ROW_HEIGHT = 22
local FRAME_WIDTH = 360
local DEFAULT_TARGET = 20

local db           -- FarmListCharDB (per character)
local frame, rows, emptyText, totalText = nil, {}, nil, nil
local ready = false -- snapshots taken after login; gains before that are not counted
local blockers = {} -- open windows during which gains are not counted as farmed

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

local function ItemIDFrom(text)
	if not text or text == "" then return nil end
	local id = text:match("item:(%d+)") or text:match("^(%d+)$")
	if id then return tonumber(id) end
	-- Plain item name: only works for items the client already knows
	local link = select(2, GetInfo(text))
	return link and tonumber(link:match("item:(%d+)")) or nil
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

local function ItemName(itemID)
	return GetInfo(itemID) or ("Item " .. itemID)
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

-- Only increases count as farmed; decreases (sold, crafted, destroyed) are ignored
local function ScanGains()
	if not ready then return end
	local blocked = IsBlocked()
	for _, entry in ipairs(List()) do
		local now = Count(entry.id)
		local before = db.snap[entry.id]
		if before and now > before and not blocked then
			AddProgress(entry, now - before)
		end
		db.snap[entry.id] = now
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
	row:EnableMouseWheel(true)

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
		GameTooltip:AddLine("Mausrad: Ziel ±1 (Shift: ±10)", 0.6, 0.8, 1)
		GameTooltip:AddLine("Strg + Mausrad: Fortschritt ±1 (Shift: ±10)", 0.6, 0.8, 1)
		GameTooltip:AddLine("Rechtsklick: entfernen", 0.6, 0.8, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnMouseWheel", function(self, delta)
		local entry = FindEntry(self.itemID)
		if not entry then return end
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
	"/farm add [Item] [Anzahl]  - Item (Link, ID oder Name) hinzufügen/Ziel setzen",
	"/farm set [Item] [Anzahl]  - Fortschritt von Hand setzen (z.B. schon vorhandene)",
	"/farm reset [Item]  - Fortschritt auf 0 (ohne Item: alle)",
	"/farm remove [Item]  - Item entfernen",
	"/farm clear  - Liste leeren",
	"/farm global  - eigene Liste / gemeinsame Liste aller Charaktere umschalten",
	"/farm price [Quelle]  - TSM-Preis für die AH-Kosten (Standard: first(dbminbuyout, dbmarket))",
	"Gezählt wird nur, was neu dazukommt. Verkaufen/Verbrauchen zieht nichts ab.",
	"Nicht gezählt: Post, Auktionshaus, Händler, Handel, Bank (offenes Fenster).",
	"Tipp: Item ins Fenster ziehen, Mausrad = Ziel, Strg+Mausrad = Fortschritt, Rechtsklick = entfernen.",
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
		local itemID = ItemIDFrom(itemPart)
		if not itemID then
			Print("Item nicht gefunden. Shift-Klick auf das Item fügt den Link ein, oder die Item-ID verwenden.")
			return
		end
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
		local itemID = ItemIDFrom(rest)
		for _, entry in ipairs(List()) do
			if not itemID or entry.id == itemID then entry.collected = 0 end
		end
		SnapshotAll()
		FarmList_Update()
	elseif cmd == "remove" or cmd == "del" then
		local itemID = ItemIDFrom(rest)
		if itemID then
			local _, i = FindEntry(itemID)
			if i then table.remove(List(), i) end
		end
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
	else
		for _, line in ipairs(HELP) do Print(line) end
	end
end

-- ============================================================================
-- Events
-- ============================================================================

-- While one of these windows is open, new items are not farmed (mail, AH, vendor, trade, bank)
local BLOCK_EVENTS = {
	MAIL_SHOW = "mail", MAIL_CLOSED = false,
	AUCTION_HOUSE_SHOW = "ah", AUCTION_HOUSE_CLOSED = false,
	MERCHANT_SHOW = "merchant", MERCHANT_CLOSED = false,
	TRADE_SHOW = "trade", TRADE_CLOSED = false,
	BANKFRAME_OPENED = "bank", BANKFRAME_CLOSED = false,
	GUILDBANKFRAME_OPENED = "guildbank", GUILDBANKFRAME_CLOSED = false,
}
local BLOCK_CLOSE = {
	MAIL_CLOSED = "mail", AUCTION_HOUSE_CLOSED = "ah", MERCHANT_CLOSED = "merchant",
	TRADE_CLOSED = "trade", BANKFRAME_CLOSED = "bank", GUILDBANKFRAME_CLOSED = "guildbank",
}

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		FarmListDB = FarmListDB or {}
		FarmListDB.items = FarmListDB.items or {}
		FarmListCharDB = FarmListCharDB or {}
		db = FarmListCharDB
		db.items = db.items or {}
		db.snap = db.snap or {}
		db.priceSource = db.priceSource or "first(dbminbuyout, dbmarket)"
		if db.shown == nil then db.shown = true end
		-- Migrate entries from version 1.0 (no progress counter yet)
		for _, list in ipairs({ db.items, FarmListDB.items }) do
			for _, entry in ipairs(list) do entry.collected = entry.collected or 0 end
		end
		CreateMainFrame()
		frame:SetShown(db.shown)
		self:UnregisterEvent("ADDON_LOADED")
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("BAG_UPDATE_DELAYED")
		self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		for name in pairs(BLOCK_EVENTS) do
			pcall(self.RegisterEvent, self, name) -- not every event exists in every client
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Fresh snapshot at login/zone change; anything gained while offline does not count
		SnapshotAll()
		ready = true
		FarmList_Update()
	elseif BLOCK_EVENTS[event] then
		ScanGains() -- count anything farmed right before opening the window
		blockers[BLOCK_EVENTS[event]] = true
	elseif BLOCK_CLOSE[event] then
		blockers[BLOCK_CLOSE[event]] = nil
		SnapshotAll() -- items received through the window are not farmed
	elseif event == "BAG_UPDATE_DELAYED" then
		ScanGains()
		if frame:IsShown() then FarmList_Update() end
	elseif frame:IsShown() then
		FarmList_Update()
	end
end)
