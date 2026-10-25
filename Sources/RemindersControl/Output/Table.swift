import Foundation

// ── Table Format (port of fmt_table / reminders_to_table_data) ────────────────

/// A single table row, mirroring the dict keys produced by `reminders_to_table_data`
/// (`id, title, list, due, completed, repeat, pri`). `repeat` is a Swift keyword, so the
/// stored property is `repeatText`.
public struct TableRow {
    public var id: String
    public var title: String
    public var list: String
    public var due: String
    public var completed: String
    public var repeatText: String
    public var pri: String

    public init(id: String, title: String, list: String, due: String, completed: String = "",
                repeatText: String, pri: String) {
        self.id = id
        self.title = title
        self.list = list
        self.due = due
        self.completed = completed
        self.repeatText = repeatText
        self.pri = pri
    }
}

/// Which timestamp column a reminder table shows. `--completed` listings are about when a
/// reminder was finished, so they replace Due with Completed.
public enum TableDateColumn {
    case due, completed
}

/// Matches Python `_strip_ansi`: regex `\033\[[0-9;]*m`.
private let ansiSGRRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

/// Port of `_strip_ansi`. Removes ANSI SGR escape sequences for width calculation.
func stripAnsi(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return ansiSGRRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}

/// EastAsianWidth W/F spans that are not covered by the emoji-presentation property. Swift
/// exposes emoji presentation but not `east_asian_width`, so the CJK and fullwidth blocks are
/// listed here; everything else in those classes is emoji and answers `isEmojiPresentation`.
private let wideScalarRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F,    // Hangul Jamo initial consonants
    0x2329...0x232A,    // angle brackets
    0x2E80...0x303E,    // CJK radicals … CJK symbols, including the ideographic space
    0x3041...0x3247,    // kana, Bopomofo, Hangul compatibility, CJK letters and months
    0x3250...0x4DBF,    // enclosed CJK, CJK unified ideographs extension A
    0x4E00...0xA48C,    // CJK unified ideographs, Yi syllables
    0xA490...0xA4C6,    // Yi radicals
    0xA960...0xA97F,    // Hangul Jamo extended-A
    0xAC00...0xD7A3,    // Hangul syllables
    0xF900...0xFAFF,    // CJK compatibility ideographs
    0xFE10...0xFE19,    // vertical forms
    0xFE30...0xFE6F,    // CJK compatibility forms, small form variants
    0xFF00...0xFF60,    // fullwidth forms
    0xFFE0...0xFFE6,    // fullwidth signs
    0x17000...0x18AFF,  // Tangut
    0x1B000...0x1B2FF,  // kana supplement and extended, Nushu
    0x20000...0x2FFFD,  // CJK unified ideographs extensions B–F
    0x30000...0x3FFFD,  // CJK unified ideographs extension G
]

/// Port of `_cell_width_char`. Terminal cells one Unicode scalar occupies.
private func cellWidth(_ scalar: Unicode.Scalar) -> Int {
    let value = scalar.value
    // Zero-width joiner and the variation selectors that pick emoji presentation.
    if value == 0x200D || (0xFE00...0xFE0F).contains(value) { return 0 }
    let properties = scalar.properties
    if properties.canonicalCombiningClass != .notReordered { return 0 }
    if properties.generalCategory == .control || properties.generalCategory == .format { return 0 }
    if properties.isEmojiPresentation { return 2 }
    return wideScalarRanges.contains { $0.contains(value) } ? 2 : 1
}

/// Port of `_visible_len`. Terminal cell width of the string as displayed (without ANSI codes).
func visibleLength(_ s: String) -> Int {
    stripAnsi(s).unicodeScalars.reduce(0) { $0 + cellWidth($1) }
}

/// Port of `_truncate_visible`. Cuts to `width` cells, leaving room for the ellipsis.
private func truncateVisible(_ s: String, _ width: Int) -> String {
    let plain = stripAnsi(s)
    if visibleLength(plain) <= width { return s }
    if width <= 1 { return String("…".prefix(max(0, width))) }
    let target = width - 1
    var out = String.UnicodeScalarView()
    var used = 0
    for scalar in plain.unicodeScalars {
        let w = cellWidth(scalar)
        if used + w > target { break }
        out.append(scalar)
        used += w
    }
    return String(out) + "…"
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
/// `includeList` drops the List column for tables that are already headed by their list, as
/// the per-child-list tables of `show <group>` are.
public func fmtTable(_ rowsData: [TableRow], maxWidth: Int = 80,
                     ansi: Ansi = Ansi(enabled: false),
                     dateColumn: TableDateColumn = .due,
                     includeList: Bool = true) -> String {
    if rowsData.isEmpty { return "" }

    // Columns in fixed order; Repeat only when at least one row has a non-empty repeat.
    var columns: [(label: String, value: (TableRow) -> String)] = [
        ("ID", { $0.id }),
        ("Title", { $0.title }),
    ]
    let titleIndex = 1
    if includeList { columns.append(("List", { $0.list })) }
    switch dateColumn {
    case .due: columns.append(("Due", { $0.due }))
    case .completed: columns.append(("Completed", { $0.completed }))
    }
    if rowsData.contains(where: { !$0.repeatText.isEmpty }) {
        columns.append(("Repeat", { $0.repeatText }))
    }
    columns.append(("Pri", { $0.pri }))

    return fmtColumns(headers: columns.map { $0.label },
                      rows: rowsData.map { row in columns.map { $0.value(row) } },
                      titleIndex: titleIndex, maxWidth: maxWidth, ansi: ansi)
}

/// The box-drawing table behind `fmtTable`, for any columns. The `titleIndex` column is capped so
/// the table fits `maxWidth`; `ansi` only bolds the headers.
public func fmtColumns(headers: [String], rows: [[String]], titleIndex: Int, maxWidth: Int = 80,
                       ansi: Ansi = Ansi(enabled: false)) -> String {
    // Natural column widths: max(visibleLen(header), max visibleLen(cell)).
    var colWidths = headers.map { $0.count }
    for row in rows {
        for (i, cell) in row.enumerated() {
            colWidths[i] = max(colWidths[i], visibleLength(cell))
        }
    }

    // Cap the Title column so the table fits `maxWidth`.
    let fixed = colWidths.enumerated()
        .filter { $0.offset != titleIndex }
        .reduce(0) { $0 + $1.element }
        + 3 * headers.count + 1
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
            if visibleLength(s) > colWidths[i] { s = truncateVisible(s, colWidths[i]) }
            cells.append(" \(pad(s, colWidths[i])) ")
        }
        return "│" + cells.joined(separator: "│") + "│"
    }

    var lines: [String] = []
    lines.append(hline("┌", "┬", "┐"))
    lines.append(rowLine(headers.map { ansi.bold($0) }))
    lines.append(hline("├", "┼", "┤"))
    for row in rows {
        lines.append(rowLine(row))
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
        let allDay = itemIsAllDay(r)
        var dueStr = ""
        if let dueVal = rowShownDate(r, calendar: calendar), dueVal != 0 {
            let dt = Date(timeIntervalSince1970: dueVal + AppleEpoch.offset)
            let dtDay = calendar.startOfDay(for: dt)
            if dtDay == sod {
                dueStr = "Today"
                let comps = calendar.dateComponents([.hour, .minute], from: dt)
                let hour = comps.hour ?? 0
                let minute = comps.minute ?? 0
                if !allDay && (hour != 0 || minute != 0) {
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

        data.append(TableRow(id: idCell, title: title, list: listCell, due: dueStr,
                             completed: tableCompletedCell(r, calendar: calendar),
                             repeatText: repeatCell, pri: priStr))
    }
    return data
}

/// Port of `_format_completed_for_table`: the completion instant as local "YYYY-MM-DD HH:MM".
private func tableCompletedCell(_ row: ReminderRow, calendar: Calendar) -> String {
    guard let raw = row.double("ZCOMPLETIONDATE"), raw != 0 else { return "" }
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                    from: Date(timeIntervalSince1970: raw + AppleEpoch.offset))
    return String(format: "%04d-%02d-%02d %02d:%02d",
                  c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
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

private func tableItemId(_ row: ReminderRow) -> String {
    if row.has("Z_PK") { return String(row.int("Z_PK") ?? 0) }
    if let i = row.int("id") { return String(i) }
    if let s = row.string("id") { return s }
    return "?"
}

/// Port of `_state_markers`. All-day (cyan 📅) first, then urgent (red ⏰), then
/// flagged (yellow ⚑); space-joined.
private func tableStateMarkers(_ row: ReminderRow, ansi: Ansi) -> String {
    var markers: [String] = []
    if itemIsAllDay(row) { markers.append(ansi.cyan("📅")) }
    if tableItemIsUrgent(row) { markers.append(ansi.red("⏰")) }
    if tableItemIsFlagged(row) { markers.append(ansi.yellow("⚑")) }
    return markers.joined(separator: " ")
}
