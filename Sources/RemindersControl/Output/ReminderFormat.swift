import Foundation

/// Optional resolver mapping a list name to its RGB color (injected later, T24).
public typealias ListColorResolver = (String) -> (Int, Int, Int)?

// ── Coloring helpers (port of color_list_name / color_by_list) ──────────────

/// Port of `color_list_name`. Returns the list name colored by its Reminders color.
public func colorListName(_ name: String?, ansi: Ansi, rgb: ListColorResolver? = nil) -> String {
    let display = safeDisplay((name?.isEmpty ?? true) ? "(none)" : name!)
    guard let name, !name.isEmpty, ansi.enabled else { return display }
    if let c = rgb?(name) { return ansi.rgb(c.0, c.1, c.2, display) }
    return ansi.cyan(display)
}

/// Port of `color_by_list`. Colors arbitrary text using the Reminders color for its list.
public func colorByList(_ text: String, listName: String?, ansi: Ansi, rgb: ListColorResolver? = nil) -> String {
    guard ansi.enabled else { return text }
    if let listName, let c = rgb?(listName) { return ansi.rgb(c.0, c.1, c.2, text) }
    if let listName, !listName.isEmpty { return ansi.cyan(text) }
    return ansi.dim(text)
}

/// Port of `_color_priority`. Colors a priority marker based on level.
func colorPriority(_ priVal: Int, ansi: Ansi) -> String {
    let p = Constants.priorityMarker[priVal] ?? ""
    if p.isEmpty { return "" }
    switch priVal {
    case 1: return ansi.red(p)
    case 5: return ansi.yellow(p)
    case 9: return ansi.green(p)
    default: return p
    }
}

// ── fmt_due ─────────────────────────────────────────────────────────────────

/// Port of `fmt_due`. `v` is the Apple-epoch ZDUEDATE (or nil).
public func fmtDue(_ v: Double?, now: Date = Date(), ansi: Ansi, calendar: Calendar = .current) -> String {
    // `if not v: return ""` — nil and 0 are falsey.
    guard let v, v != 0 else { return "" }
    let dt = Date(timeIntervalSince1970: v + AppleEpoch.offset)

    let today = calendar.startOfDay(for: now)
    let dtDay = calendar.startOfDay(for: dt)

    // Python checks date()==today first, then date()==tomorrow, then dt<now, else date.
    if dtDay == today {
        let comps = calendar.dateComponents([.hour, .minute], from: dt)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        if hour != 0 || minute != 0 {
            return String(format: " (today %02d:%02d)", hour, minute)
        }
        return " (today)"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), dtDay == tomorrow {
        return " (tomorrow)"
    }
    if dt < now {
        // (now - dt).days — whole days, floored toward zero (positive interval).
        let seconds = now.timeIntervalSince(dt)
        let days = Int(seconds / 86_400)
        let label = " (overdue \(days)d)"
        return ansi.red(label)
    }
    let dateComps = calendar.dateComponents([.year, .month, .day], from: dt)
    let label = String(format: " (%04d-%02d-%02d)", dateComps.year ?? 0, dateComps.month ?? 0, dateComps.day ?? 0)
    return label
}

// ── recurrence_summary ────────────────────────────────────────────────────────

/// Small lookup over the ordered recurrence pairs produced by `recurrenceFromRow`.
private func recurrenceField(_ rec: [(String, JSONValue)], _ key: String) -> JSONValue? {
    rec.first(where: { $0.0 == key })?.1
}

/// Port of `recurrence_summary`. Operates on `recurrenceFromRow` output.
public func recurrenceSummary(_ rec: [(String, JSONValue)]) -> String {
    guard !rec.isEmpty else { return "" }
    guard case let .string(frequency)? = recurrenceField(rec, "frequency") else { return "" }

    // interval — int(recurrence.get("interval") or 1)
    var interval = 1
    if case let .int(i)? = recurrenceField(rec, "interval") { interval = i == 0 ? 1 : i }

    // units map: only daily/weekly/monthly/yearly are valid frequencies.
    let plurals: [String: String] = ["daily": "days", "weekly": "weeks", "monthly": "months", "yearly": "years"]
    guard let plural = plurals[frequency] else { return "" }

    var label = interval == 1 ? frequency : "every \(interval) \(plural)"

    // weekly + non-empty daysOfWeek → " Mon, Wed" (fallback to str(day) for unknown, matching source).
    if frequency == "weekly", case let .array(days)? = recurrenceField(rec, "daysOfWeek"), !days.isEmpty {
        let names: [String] = days.compactMap { day in
            let n: Int
            switch day {
            case let .int(i): n = i
            case let .double(d): n = Int(d)
            default: return nil
            }
            return Constants.recurrenceDayNames[n] ?? String(n)
        }
        if !names.isEmpty { label += " " + names.joined(separator: ", ") }
    }

    // monthly + non-empty daysOfMonth → " on 1, 15"
    if frequency == "monthly", case let .array(dom)? = recurrenceField(rec, "daysOfMonth"), !dom.isEmpty {
        let nums: [String] = dom.compactMap { v in
            switch v {
            case let .int(i): return String(i)
            case let .double(d): return String(Int(d))
            default: return nil
            }
        }
        if !nums.isEmpty { label += " on " + nums.joined(separator: ", ") }
    }

    // count present → " x{count}"; else if endDate present → " until {endDate[:10]}"
    if case let .int(count)? = recurrenceField(rec, "count"), count != 0 {
        label += " x\(count)"
    } else if case let .string(endDate)? = recurrenceField(rec, "endDate") {
        label += " until \(endDate.prefix(10))"
    }

    return label
}

// ── item field helpers (mirror _item_* / *_from_item) ─────────────────────────

private func itemPriorityValue(_ row: ReminderRow) -> Int {
    if row.has("ZPRIORITY") { return row.int("ZPRIORITY") ?? 0 }
    return ["high": 1, "medium": 5, "low": 9][(row.string("priority") ?? "none").lowercased()] ?? 0
}

private func itemIsFlagged(_ row: ReminderRow) -> Bool {
    if row.has("ZFLAGGED") { return (row.int("ZFLAGGED") ?? 0) != 0 }
    return (row.int("flagged") ?? 0) != 0
}

private func itemIsUrgent(_ row: ReminderRow) -> Bool {
    if row.has("ZISURGENTSTATEENABLEDFORCURRENTUSER") {
        return (row.int("ZISURGENTSTATEENABLEDFORCURRENTUSER") ?? 0) != 0
    }
    return (row.int("urgent") ?? 0) != 0
}

private func itemListName(_ row: ReminderRow) -> String? {
    if row.has("list_name") { return row.string("list_name") }
    return row.string("list")
}

private func itemURL(_ row: ReminderRow) -> String? {
    if row.has("ZICSURL") { return row.string("ZICSURL") }
    return row.string("url")
}

private func itemTitle(_ row: ReminderRow) -> String? {
    if row.has("ZTITLE") { return row.string("ZTITLE") }
    return row.string("title")
}

private func itemNotes(_ row: ReminderRow) -> String? {
    if row.has("ZNOTES") { return row.string("ZNOTES") }
    return row.string("notes")
}

private func itemCompleted(_ row: ReminderRow) -> Bool {
    if row.has("ZCOMPLETED") { return (row.int("ZCOMPLETED") ?? 0) != 0 }
    return (row.int("completed") ?? 0) != 0
}

private func itemDueDate(_ row: ReminderRow) -> Double? {
    if row.has("ZDUEDATE") { return row.double("ZDUEDATE") }
    return row.double("dueDate")
}

private func itemId(_ row: ReminderRow) -> String {
    if row.has("Z_PK") { return String(row.int("Z_PK") ?? 0) }
    if let i = row.int("id") { return String(i) }
    if let s = row.string("id") { return s }
    return "?"
}

/// Port of `_state_markers`. Urgent (red ⏰) first, then flagged (yellow ⚑); space-joined.
private func stateMarkers(_ row: ReminderRow, ansi: Ansi) -> String {
    var markers: [String] = []
    if itemIsUrgent(row) { markers.append(ansi.red("⏰")) }
    if itemIsFlagged(row) { markers.append(ansi.yellow("⚑")) }
    return markers.joined(separator: " ")
}

// ── fmt ───────────────────────────────────────────────────────────────────────

/// Port of `fmt`. Human-readable single-reminder line (plus verbose detail lines).
public func fmt(_ row: ReminderRow, tags: [String], subtaskCount: Int, ansi: Ansi,
                now: Date = Date(), verbose: Bool = false, indent: String = "",
                rgb: ListColorResolver? = nil) -> String {
    let completed = itemCompleted(row)
    let status = completed ? ansi.green("[x]") : ansi.dim("[ ]")

    let markers = stateMarkers(row, ansi: ansi)
    let markerStr = markers.isEmpty ? "" : " \(markers)"

    let priVal = itemPriorityValue(row)
    let tagStr0 = tags.isEmpty ? "" : " " + tags.map { "#\(safeDisplay($0))" }.joined(separator: " ")
    let subStr0 = subtaskCount > 0 ? " [\(subtaskCount) subtask\(subtaskCount == 1 ? "" : "s")]" : ""
    let priStr = (Constants.priorityMarker[priVal]?.isEmpty == false) ? " \(colorPriority(priVal, ansi: ansi))" : ""

    let listName = itemListName(row)
    let idStr = colorByList("#\(itemId(row))", listName: listName, ansi: ansi, rgb: rgb)

    var title = safeDisplay((itemTitle(row)?.isEmpty ?? true) ? "(untitled)" : itemTitle(row)!)
    var dueStr = fmtDue(itemDueDate(row), now: now, ansi: ansi)

    let summary = recurrenceSummary(recurrenceFromRow(row, ts: { AppleEpoch.ts($0) }) ?? [])
    var recurStr = summary.isEmpty ? "" : " \(ansi.magenta("↻ \(summary)"))"
    var tagStr = tagStr0
    var subStr = subStr0

    if completed {
        title = ansi.dim(ansi.strikethrough(title))
        dueStr = ansi.dim(dueStr)
        recurStr = ansi.dim(recurStr)
        tagStr = ansi.dim(tagStr)
        subStr = ansi.dim(subStr)
    }

    var parts = ["\(indent)\(status) \(idStr)\(priStr)\(markerStr) \(title)\(dueStr)\(recurStr)\(tagStr)\(subStr)"]

    if verbose {
        if let listName, !listName.isEmpty {
            parts.append("\(indent)    List: \(colorListName(listName, ansi: ansi, rgb: rgb))")
        }
        if let notes = itemNotes(row), !notes.isEmpty {
            parts.append("\(indent)    Notes: \(ansi.dim(String(safeDisplay(notes).prefix(200))))")
        }
        if let url = itemURL(row), !url.isEmpty {
            parts.append("\(indent)    URL: \(ansi.dim(safeDisplay(url)))")
        }
        if !summary.isEmpty {
            parts.append("\(indent)    Repeats: \(ansi.magenta(summary))")
        }
        let early = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        if !early.isEmpty {
            let labels = early.compactMap { alert -> String? in
                if case let .string(s)? = alert.first(where: { $0.0 == "label" })?.1 { return s }
                return nil
            }.joined(separator: ", ")
            parts.append("\(indent)    Early: \(ansi.cyan(labels))")
        }
        if itemIsFlagged(row) {
            parts.append("\(indent)    Flagged: \(ansi.yellow("Yes"))")
        }
        if itemIsUrgent(row) {
            parts.append("\(indent)    Urgent: \(ansi.red("Yes"))")
        }
    }

    return parts.joined(separator: "\n")
}
