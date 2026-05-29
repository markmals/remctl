import Foundation

// ── Table Format (port of fmt_table / reminders_to_table_data) ────────────────

/// A single table row, mirroring the dict keys produced by `reminders_to_table_data`
/// (`id, title, list, due, repeat, pri`). `repeat` is a Swift keyword, so the
/// stored property is `repeatText`.
public struct TableRow {
    public var id: String
    public var title: String
    public var list: String
    public var due: String
    public var repeatText: String
    public var pri: String

    public init(id: String, title: String, list: String, due: String, repeatText: String, pri: String) {
        self.id = id
        self.title = title
        self.list = list
        self.due = due
        self.repeatText = repeatText
        self.pri = pri
    }
}

/// Matches Python `_strip_ansi`: regex `\033\[[0-9;]*m`.
private let ansiSGRRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

/// Port of `_strip_ansi`. Removes ANSI SGR escape sequences for width calculation.
func stripAnsi(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return ansiSGRRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}

/// Port of `_visible_len`. Length of string as displayed (without ANSI codes).
func visibleLength(_ s: String) -> Int {
    stripAnsi(s).count
}

/// Port of `_pad`. Left-justify to `width` accounting for ANSI codes.
private func pad(_ s: String, _ width: Int) -> String {
    let visible = visibleLength(s)
    return s + String(repeating: " ", count: max(0, width - visible))
}

/// Port of `fmt_table`. Formats data as a Unicode box-drawing table.
///
/// `ansi` controls only header bolding (`C.bold(h)` in source); cell contents are already
/// colored by `remindersToTableData`. Defaults to disabled so uncolored output is the
/// common case; pass an enabled `Ansi` to bold headers when emitting a colored table.
public func fmtTable(_ rowsData: [TableRow], maxWidth: Int = 80,
                     ansi: Ansi = Ansi(enabled: false)) -> String {
    if rowsData.isEmpty { return "" }

    // Columns in fixed order; Repeat only when at least one row has a non-empty repeat.
    // (key, header, value-accessor)
    var columns: [(label: String, value: (TableRow) -> String)] = [
        ("ID", { $0.id }),
        ("Title", { $0.title }),
        ("List", { $0.list }),
        ("Due", { $0.due }),
    ]
    let titleIndex = 1
    if rowsData.contains(where: { !$0.repeatText.isEmpty }) {
        columns.append(("Repeat", { $0.repeatText }))
    }
    columns.append(("Pri", { $0.pri }))

    let headers = columns.map { $0.label }

    // Natural column widths: max(visibleLen(header), max visibleLen(cell)).
    var colWidths = headers.map { $0.count }
    for row in rowsData {
        for (i, col) in columns.enumerated() {
            colWidths[i] = max(colWidths[i], visibleLength(col.value(row)))
        }
    }

    // Cap the Title column so the table fits `maxWidth`.
    let fixed = colWidths.enumerated()
        .filter { $0.offset != titleIndex }
        .reduce(0) { $0 + $1.element }
        + 3 * columns.count + 1
    let maxTitle = max(10, maxWidth - fixed)
    colWidths[titleIndex] = min(colWidths[titleIndex], maxTitle)

    func hline(_ left: String, _ mid: String, _ right: String, fill: String = "─") -> String {
        var parts = [left]
        for (i, w) in colWidths.enumerated() {
            parts.append(String(repeating: fill, count: w + 2))
            parts.append(i < colWidths.count - 1 ? mid : "")
        }
        parts.append(right)
        return parts.joined()
    }

    func rowLine(_ vals: [String]) -> String {
        var cells: [String] = []
        for (i, v) in vals.enumerated() {
            var s = v
            // Truncate (by visible length): plain[:width-1] + "…".
            if visibleLength(s) > colWidths[i] {
                let plain = stripAnsi(s)
                s = String(plain.prefix(colWidths[i] - 1)) + "…"
            }
            cells.append(" \(pad(s, colWidths[i])) ")
        }
        return "│" + cells.joined(separator: "│") + "│"
    }

    var lines: [String] = []
    lines.append(hline("┌", "┬", "┐"))
    lines.append(rowLine(headers.map { ansi.bold($0) }))
    lines.append(hline("├", "┼", "┤"))
    for row in rowsData {
        lines.append(rowLine(columns.map { $0.value(row) }))
    }
    lines.append(hline("└", "┴", "┘"))
    return lines.joined(separator: "\n")
}

/// Port of `reminders_to_table_data`. Converts reminder rows to table-friendly rows.
///
/// `ansi` controls coloring of cell contents (markers, priority, due, repeat). The list
/// cell is colored via `colorListName` when `ansi.enabled`, else `safeDisplay`-ed.
public func remindersToTableData(_ items: [ReminderRow], ansi: Ansi, now: Date = Date(),
                                 rgb: ListColorResolver? = nil,
                                 calendar: Calendar = .current) -> [TableRow] {
    var data: [TableRow] = []
    let sod = calendar.startOfDay(for: now)
    let tomorrowSod = calendar.date(byAdding: .day, value: 1, to: sod)!

    for r in items {
        // ── due ──
        var dueStr = ""
        if let dueVal = tableItemDueDate(r), dueVal != 0 {
            let dt = Date(timeIntervalSince1970: dueVal + AppleEpoch.offset)
            let dtDay = calendar.startOfDay(for: dt)
            if dtDay == sod {
                dueStr = "Today"
                let comps = calendar.dateComponents([.hour, .minute], from: dt)
                let hour = comps.hour ?? 0
                let minute = comps.minute ?? 0
                if hour != 0 || minute != 0 {
                    dueStr += String(format: " %02d:%02d", hour, minute)
                }
            } else if dtDay == tomorrowSod {
                dueStr = "Tomorrow"
            } else if dt < now {
                let days = Int(now.timeIntervalSince(dt) / 86_400)
                dueStr = ansi.red("Overdue \(days)d")
            } else {
                let c = calendar.dateComponents([.year, .month, .day], from: dt)
                dueStr = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
        }

        // ── pri ──
        let priVal = tableItemPriorityValue(r)
        let priStr = (Constants.priorityMarker[priVal]?.isEmpty == false) ? colorPriority(priVal, ansi: ansi) : ""

        // ── title (+ markers) ──
        var title = safeDisplay((tableItemTitle(r)?.isEmpty ?? true) ? "(untitled)" : tableItemTitle(r)!)
        let markers = tableStateMarkers(r, ansi: ansi)
        if !markers.isEmpty {
            title = "\(markers) \(title)"
        }

        // ── list ──
        let listName = tableItemListName(r) ?? ""
        let listCell: String
        if ansi.enabled {
            listCell = colorListName(listName, ansi: ansi, rgb: rgb)
        } else {
            listCell = safeDisplay(listName)
        }

        // ── repeat ──
        let summary = recurrenceSummary(recurrenceFromRow(r, ts: { AppleEpoch.ts($0) }) ?? [])
        let repeatCell = summary.isEmpty ? "" : ansi.magenta(summary)

        // ── id ──
        let idCell = colorByList("#\(tableItemId(r))", listName: tableItemListName(r), ansi: ansi, rgb: rgb)

        data.append(TableRow(id: idCell, title: title, list: listCell,
                             due: dueStr, repeatText: repeatCell, pri: priStr))
    }
    return data
}

// ── item field helpers (mirror _item_* / *_from_item; local copies to keep these
//    `private` symbols decoupled from ReminderFormat.swift) ─────────────────────

private func tableItemPriorityValue(_ row: ReminderRow) -> Int {
    if row.has("ZPRIORITY") { return row.int("ZPRIORITY") ?? 0 }
    return ["high": 1, "medium": 5, "low": 9][(row.string("priority") ?? "none").lowercased()] ?? 0
}

private func tableItemIsFlagged(_ row: ReminderRow) -> Bool {
    if row.has("ZFLAGGED") { return (row.int("ZFLAGGED") ?? 0) != 0 }
    return (row.int("flagged") ?? 0) != 0
}

private func tableItemIsUrgent(_ row: ReminderRow) -> Bool {
    if row.has("ZISURGENTSTATEENABLEDFORCURRENTUSER") {
        return (row.int("ZISURGENTSTATEENABLEDFORCURRENTUSER") ?? 0) != 0
    }
    return (row.int("urgent") ?? 0) != 0
}

private func tableItemListName(_ row: ReminderRow) -> String? {
    if row.has("list_name") { return row.string("list_name") }
    return row.string("list")
}

private func tableItemTitle(_ row: ReminderRow) -> String? {
    if row.has("ZTITLE") { return row.string("ZTITLE") }
    return row.string("title")
}

private func tableItemDueDate(_ row: ReminderRow) -> Double? {
    if row.has("ZDUEDATE") { return row.double("ZDUEDATE") }
    return row.double("dueDate")
}

private func tableItemId(_ row: ReminderRow) -> String {
    if row.has("Z_PK") { return String(row.int("Z_PK") ?? 0) }
    if let i = row.int("id") { return String(i) }
    if let s = row.string("id") { return s }
    return "?"
}

/// Port of `_state_markers`. Urgent (red ⏰) first, then flagged (yellow ⚑); space-joined.
private func tableStateMarkers(_ row: ReminderRow, ansi: Ansi) -> String {
    var markers: [String] = []
    if tableItemIsUrgent(row) { markers.append(ansi.red("⏰")) }
    if tableItemIsFlagged(row) { markers.append(ansi.yellow("⚑")) }
    return markers.joined(separator: " ")
}
