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

/// Port of `fmt_due`. `v` is the Apple-epoch due value (or nil); pass `allDay` to
/// suppress the time-of-day component (all-day items carry no meaningful time).
public func fmtDue(_ v: Double?, now: Date = Date(), ansi: Ansi, calendar: Calendar = .current,
                   allDay: Bool = false) -> String {
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
        if !allDay && (hour != 0 || minute != 0) {
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

/// Port of `recurrence_summary` (upstream c84fbca). Operates on `recurrenceFromRow` output and
/// on writer-shaped rules (`--via-eventkit` reads), which carry `weekNumbers` instead of
/// `daysOfWeekDetailed`.
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

    // " Mon, Wed" / " 4th Fri" / " last Fri"
    if frequency != "daily" {
        let names = recurrenceDayLabels(rec)
        if !names.isEmpty { label += " " + names.joined(separator: ", ") }
    }

    // monthly + non-empty daysOfMonth → " on 1, 15"
    if frequency == "monthly", case let .array(dom)? = recurrenceField(rec, "daysOfMonth"), !dom.isEmpty {
        let nums = dom.compactMap { recurrenceJSONInt($0).map(String.init) }
        if !nums.isEmpty { label += " on " + nums.joined(separator: ", ") }
    }

    // count → ", 5 times" (not " x5", which reads as the xN interval input token);
    // else endDate → " until {endDate[:10]}"
    if case let .int(count)? = recurrenceField(rec, "count"), count != 0 {
        label += ", \(count) time\(count == 1 ? "" : "s")"
    } else if case let .string(endDate)? = recurrenceField(rec, "endDate") {
        label += " until \(endDate.prefix(10))"
    }

    return label
}

/// Weekday labels honoring week pinning. Reminders' stored `daysOfWeekDetailed` wins when
/// present (weekNumber 0 = any week); writer-shaped rules carry a parallel `weekNumbers` list,
/// which may be missing or short (missing entries stay unpinned).
private func recurrenceDayLabels(_ rec: [(String, JSONValue)]) -> [String] {
    var pairs: [(day: Int, week: Int)] = []
    if case let .array(detailed)? = recurrenceField(rec, "daysOfWeekDetailed"), !detailed.isEmpty {
        for entry in detailed {
            guard case let .object(fields) = entry,
                  let day = fields.first(where: { $0.0 == "dayOfTheWeek" }).flatMap({ recurrenceJSONInt($0.1) })
            else { continue }
            let week = fields.first(where: { $0.0 == "weekNumber" }).flatMap({ recurrenceJSONInt($0.1) }) ?? 0
            pairs.append((day, week))
        }
    } else if case let .array(days)? = recurrenceField(rec, "daysOfWeek") {
        var weeks: [JSONValue] = []
        if case let .array(w)? = recurrenceField(rec, "weekNumbers") { weeks = w }
        for (index, value) in days.enumerated() {
            guard let day = recurrenceJSONInt(value) else { continue }
            let week = index < weeks.count ? recurrenceJSONInt(weeks[index]) ?? 0 : 0
            pairs.append((day, week))
        }
    }
    return pairs.map { recurrenceWeekLabel(week: $0.week, day: Constants.recurrenceDayNames[$0.day] ?? String($0.day)) }
}

/// "Fri", "4th Fri", "last Fri", "2nd-last Fri".
private func recurrenceWeekLabel(week: Int, day: String) -> String {
    if week == 0 { return day }
    if week == -1 { return "last \(day)" }
    let n = abs(week)
    let ordinal = "\(n)\(Constants.recurrenceOrdinalSuffixes[n] ?? "th")"
    return week > 0 ? "\(ordinal) \(day)" : "\(ordinal)-last \(day)"
}

private func recurrenceJSONInt(_ value: JSONValue) -> Int? {
    switch value {
    case let .int(i): return i
    case let .double(d): return Int(d)
    default: return nil
    }
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

/// Port of `_item_is_all_day`. True when ZALLDAY (or JSON `allDay`) is set.
func itemIsAllDay(_ row: ReminderRow) -> Bool {
    if row.has("ZALLDAY") { return (row.int("ZALLDAY") ?? 0) != 0 }
    return (row.int("allDay") ?? 0) != 0
}

/// Port of `row_effective_due`. Raw due timestamp, with the local day for an all-day item:
/// Reminders stores all-day ZDUEDATE at UTC midnight (which can fall on the previous local
/// day west of UTC), so use ZDISPLAYDATEDATE when present.
func rowEffectiveDue(_ row: ReminderRow, calendar: Calendar = .current,
                     hasAbsoluteAlarm: (() -> Bool)? = nil) -> Double? {
    let due = row.has("ZDUEDATE")
        ? timedDueRaw(row, calendar: calendar, hasAbsoluteAlarm: hasAbsoluteAlarm)
        : row.double("dueDate")
    if itemIsAllDay(row) {
        if row.has("ZDISPLAYDATEDATE"), let disp = row.double("ZDISPLAYDATEDATE") { return disp }
        if let disp = row.double("displayDate") { return disp }
    }
    return due
}

/// Port of `row_shown_date` (upstream f9b6411). Raw timestamp Reminders.app lists and
/// labels the reminder at. Matches `dueFilterExpr`: the display date when Reminders stores
/// one, otherwise the due date.
func rowShownDate(_ row: ReminderRow, calendar: Calendar = .current) -> Double? {
    if row.has("ZDISPLAYDATEDATE"), let disp = row.double("ZDISPLAYDATEDATE") { return disp }
    if let disp = row.double("displayDate") { return disp }
    return rowEffectiveDue(row, calendar: calendar)
}

private func itemId(_ row: ReminderRow) -> String {
    if row.has("Z_PK") { return String(row.int("Z_PK") ?? 0) }
    if let i = row.int("id") { return String(i) }
    if let s = row.string("id") { return s }
    return "?"
}

/// Port of `_state_markers`. All-day (cyan 📅) first, then urgent (red ⏰), then
/// flagged (yellow ⚑); space-joined.
private func stateMarkers(_ row: ReminderRow, ansi: Ansi) -> String {
    var markers: [String] = []
    if itemIsAllDay(row) { markers.append(ansi.cyan("📅")) }
    if itemIsUrgent(row) { markers.append(ansi.red("⏰")) }
    if itemIsFlagged(row) { markers.append(ansi.yellow("⚑")) }
    return markers.joined(separator: " ")
}

// ── fmt ───────────────────────────────────────────────────────────────────────

/// Port of `fmt`. Human-readable single-reminder line (plus verbose detail lines).
/// `earlyFallback` reads Early Reminders from `ZREMCDDUEDATEDELTAALERT` for a store whose
/// envelope blob is absent or stale (upstream 088fab4); it takes the reminder's ckid.
/// `badges` ends the line with 🔗/🌄 markers; they stay out of every machine-readable output.
public func fmt(_ row: ReminderRow, tags: [String], subtaskCount: Int, ansi: Ansi,
                now: Date = Date(), verbose: Bool = false, indent: String = "",
                rgb: ListColorResolver? = nil, assigneeName: String? = nil,
                earlyFallback: ((String) -> [[(String, JSONValue)]])? = nil,
                badges: ReminderBadges = ReminderBadges()) -> String {
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
    let allDay = itemIsAllDay(row)
    var dueStr = fmtDue(rowShownDate(row), now: now, ansi: ansi, allDay: allDay)

    let summary = recurrenceSummary(recurrenceFromRow(row, ts: { AppleEpoch.ts($0) }) ?? [])
    var recurStr = summary.isEmpty ? "" : " \(ansi.magenta("↻ \(summary)"))"
    // " @Name" between recurrence and tags (upstream 683c362 assign_str).
    var assignStr = (assigneeName?.isEmpty == false) ? " @\(safeDisplay(assigneeName!))" : ""
    var tagStr = tagStr0
    var subStr = subStr0

    if completed {
        title = ansi.dim(ansi.strikethrough(title))
        dueStr = ansi.dim(dueStr)
        recurStr = ansi.dim(recurStr)
        assignStr = ansi.dim(assignStr)
        tagStr = ansi.dim(tagStr)
        subStr = ansi.dim(subStr)
    }

    // Badges close the line, after tags and the subtask count, and keep their color on a
    // completed reminder (upstream fmt badge_str).
    var parts = ["\(indent)\(status) \(idStr)\(priStr)\(markerStr) \(title)\(dueStr)\(recurStr)\(assignStr)\(tagStr)\(subStr)\(badges.suffix)"]

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
        if allDay {
            parts.append("\(indent)    All-day: \(ansi.cyan("Yes"))")
        }
        var early = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        if early.isEmpty, let earlyFallback, let ck = row.string("ZCKIDENTIFIER"), !ck.isEmpty {
            early = earlyFallback(ck)
        }
        if !early.isEmpty {
            let labels = early.compactMap { alert -> String? in
                if case let .string(s)? = alert.first(where: { $0.0 == "label" })?.1 { return s }
                return nil
            }.joined(separator: ", ")
            parts.append("\(indent)    Early: \(ansi.cyan(labels))")
        }
        if let assigneeName, !assigneeName.isEmpty {
            parts.append("\(indent)    Assigned: \(ansi.cyan(safeDisplay(assigneeName)))")
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
