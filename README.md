# FarmList

Kleine Farmliste für WoW Forever: Items mit Zielmenge eintragen, die Liste zählt mit, was du sammelst. Ist TSM geladen, zeigt jede Zeile, was die fehlende Menge im Auktionshaus kosten würde.

## So wird gezählt

- **Nur was neu dazukommt, zählt.** Brauchst du 500 und sammelst 100, steht dort `100 / 500`. Auch wenn du die 100 danach verkaufst oder verbraucht, bleibt es bei 100.
- Was beim Hinzufügen schon in Taschen oder Bank liegt, zählt nicht. Mit `/farm set [Item] 50` oder Strg + Mausrad trägst du vorhandene Items von Hand nach.
- **Nicht gezählt** wird, was du bei offener Post, Auktionshaus, Händler, Handel oder Bank bekommst. Das ist nicht gefarmt.
- Bank und Taschen werden zusammen gezählt. Einlagern oder Abheben verändert den Fortschritt also nicht.
- Was du herstellst, zählt (z. B. Barren aus dem Schmelzen).

## Bedienung

- **Hinzufügen:** Item ins Fenster ziehen (Ziel 20) oder `/farm add [Item] 500`. Item per Shift-Klick verlinken, oder ID bzw. Name angeben.
- **Ziel ändern:** Mausrad über der Zeile, ±1 (mit Shift ±10).
- **Fortschritt korrigieren:** Strg + Mausrad, ±1 (mit Shift ±10).
- **Entfernen:** Rechtsklick auf die Zeile.
- **Fenster verschieben:** mit der linken Maustaste ziehen.

| Befehl | Wirkung |
|---|---|
| `/farm` | Fenster an/aus |
| `/farm add [Item] [Anzahl]` | Item hinzufügen oder Ziel setzen |
| `/farm set [Item] [Anzahl]` | Fortschritt von Hand setzen |
| `/farm reset [Item]` | Fortschritt auf 0 (ohne Item: alle) |
| `/farm remove [Item]` | Item entfernen |
| `/farm clear` | Liste leeren |
| `/farm global` | eigene Liste ↔ gemeinsame Liste aller Charaktere |
| `/farm price [Quelle]` | TSM-Preisquelle für die AH-Kosten (Standard `first(dbminbuyout, dbmarket)`) |

Ist ein Ziel erreicht, wird die Zeile grün, es gibt einen Sound und eine Chatmeldung.

Die Liste ist standardmäßig pro Charakter. Mit `/farm global` nutzt dieser Charakter die gemeinsame Liste. Was jeder Charakter dort farmt, wird zusammengezählt.

## License

MIT, see [LICENSE](LICENSE).
