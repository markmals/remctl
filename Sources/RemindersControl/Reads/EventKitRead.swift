import Foundation

// ──────────────────────────────────────────────────────────────────────────────
// Limited EventKit read fallback (--via-eventkit) — port of upstream 391b1c9.
//
// This file is the PURE layer: validation, payload shaping, human rendering.
// The live EKEventStore fetch lives in EventKitReader.swift (not CI-testable).
// In our in-process fork there is no bridge subprocess, so the upstream
// "bridge_unavailable" error path does not exist; EventKit errors map to
// eventkit_read_failed (exit 1).
// ──────────────────────────────────────────────────────────────────────────────

public enum EventKitRead {
    /// EVENTKIT_READ_ID_WARNING (remctl:2420).
    public static let idWarning =
        "eventKitId is not a RemCTL numeric id and cannot be passed to info, edit, "
        + "done, delete, link, open, subtasks, or any other numeric-id command."

    /// EVENTKIT_READ_LIMITATIONS (remctl:2424).
    public static let limitations = [
        "No RemCTL numeric ids",
        "No sections",
        "No synced tags",
        "No urgent state",
        "No private rich links",
        "No templates or smart-list internals",
    ]
}

/// A --via-eventkit failure: `code` and `exitCode` mirror `_eventkit_read_error`
/// (eventkit_read_unsupported → 2, eventkit_read_failed → 1).
public struct EventKitReadError: Error {
    public let message: String
    public let code: String
    public let exitCode: Int32
    public init(_ message: String, code: String = "eventkit_read_unsupported", exitCode: Int32 = 2) {
        self.message = message
        self.code = code
        self.exitCode = exitCode
    }
}

/// Port of `validate_eventkit_read_args` (remctl:2472).
public func validateEventKitReadArgs(
    listId: Int?, formatIsTable: Bool,
    requiresListName: Bool = false, listName: String? = nil
) throws {
    if listId != nil {
        throw EventKitReadError("--via-eventkit cannot use RemCTL numeric list ids. Pass a list name instead.")
    }
    if formatIsTable {
        throw EventKitReadError("--via-eventkit does not support table output because EventKit ids are long and non-chainable. Use plain or JSON output.")
    }
    if requiresListName && (listName == nil || listName!.isEmpty) {
        throw EventKitReadError("--via-eventkit show requires a list name.")
    }
}

/// The `_eventkit_read_error` stderr body (without exiting). JSON mode emits the
/// compact structured payload; human mode the two-line message + fallback note.
public func eventKitReadErrorText(_ error: EventKitReadError, json: Bool) -> String {
    if json {
        let payload: JSONValue = .object([
            ("status", .string("error")),
            ("code", .string(error.code)),
            ("message", .string(error.message)),
            ("source", .string("eventkit")),
            ("fidelity", .string("limited")),
            ("idWarning", .string(EventKitRead.idWarning)),
        ])
        return payload.serialized(indent: nil, ensureAscii: true) + "\n"
    }
    return "Error: \(error.message)\nEventKit fallback note: \(EventKitRead.idWarning)\n"
}

/// One fetched reminder, decoupled from EKReminder so shaping/rendering is testable.
public struct EventKitItemSnapshot {
    public var eventKitId: String
    public var externalId: String?
    public var title: String
    public var list: String
    public var completed: Bool
    public var priority: Int                      // raw EK priority 0-9
    public var notes: String?
    public var url: String?
    public var dueDate: Date?
    public var allDay: Bool
    public var createdDate: Date?
    public var completionDate: Date?
    public var alarms: [JSONValue]
    public var recurrence: [(String, JSONValue)]?

    public init(eventKitId: String, externalId: String? = nil, title: String, list: String,
                completed: Bool = false, priority: Int = 0, notes: String? = nil, url: String? = nil,
                dueDate: Date? = nil, allDay: Bool = false, createdDate: Date? = nil,
                completionDate: Date? = nil, alarms: [JSONValue] = [], recurrence: [(String, JSONValue)]? = nil) {
        self.eventKitId = eventKitId; self.externalId = externalId; self.title = title; self.list = list
        self.completed = completed; self.priority = priority; self.notes = notes; self.url = url
        self.dueDate = dueDate; self.allDay = allDay; self.createdDate = createdDate
        self.completionDate = completionDate; self.alarms = alarms; self.recurrence = recurrence
    }
}

/// Bridge `priorityName` (391b1c9): 1-4 high, 5 medium, 6-9 low, else none.
func eventKitPriorityName(_ value: Int) -> String {
    if value >= 1 && value <= 4 { return "high" }
    if value == 5 { return "medium" }
    if value >= 6 && value <= 9 { return "low" }
    return "none"
}

/// The marker value (1/5/9/0) for the priority bucket — Python's
/// `_priority_value_from_item` over the emitted name.
func eventKitPriorityMarkerValue(_ value: Int) -> Int {
    switch eventKitPriorityName(value) {
    case "high": return 1
    case "medium": return 5
    case "low": return 9
    default: return 0
    }
}

/// Serialize one snapshot to the sanitized EVENTKIT_ITEM_KEYS item object
/// (bridge `reminderPayload` fields; never a RemCTL numeric `id`).
public func eventKitItemJSON(_ s: EventKitItemSnapshot, calendar: Calendar = .current) -> [(String, JSONValue)] {
    var o: [(String, JSONValue)] = [
        ("eventKitId", .string(s.eventKitId)),
        ("title", .string(s.title)),
        ("list", .string(s.list)),
        ("completed", .bool(s.completed)),
        ("priority", .string(eventKitPriorityName(s.priority))),
    ]
    if let externalId = s.externalId { o.append(("externalId", .string(externalId))) }
    if let notes = s.notes, !notes.isEmpty { o.append(("notes", .string(notes))) }
    if let url = s.url, !url.isEmpty { o.append(("url", .string(url))) }
    if let due = s.dueDate {
        o.append(("dueDate", .string(isoLocalDateTime(appleSeconds: AppleEpoch.toTs(due), calendar: calendar))))
        o.append(("allDay", .bool(s.allDay)))
    }
    if let created = s.createdDate {
        o.append(("createdDate", .string(isoLocalDateTime(appleSeconds: AppleEpoch.toTs(created), calendar: calendar))))
    }
    if let completion = s.completionDate {
        o.append(("completionDate", .string(isoLocalDateTime(appleSeconds: AppleEpoch.toTs(completion), calendar: calendar))))
    }
    if !s.alarms.isEmpty { o.append(("alarms", .array(s.alarms))) }
    if let rec = s.recurrence { o.append(("recurrence", .object(rec))) }
    return o
}

/// The JSON wrapper object (`limited_eventkit_read` return shape, remctl:2487):
/// {source, fidelity, mode, idWarning, limitations, items} — NOT the normal
/// read-command array.
public func eventKitReadPayloadJSON(mode: String, items: [EventKitItemSnapshot], calendar: Calendar = .current) -> JSONValue {
    .object([
        ("source", .string("eventkit")),
        ("fidelity", .string("limited")),
        ("mode", .string(mode)),
        ("idWarning", .string(EventKitRead.idWarning)),
        ("limitations", .array(EventKitRead.limitations.map { .string($0) })),
        ("items", .array(items.map { .object(eventKitItemJSON($0, calendar: calendar)) })),
    ])
}

/// Port of `fmt_eventkit_item` (remctl:2517).
public func fmtEventKitItem(_ item: EventKitItemSnapshot, verbose: Bool = false, indent: String = "",
                            ansi: Ansi, now: Date = Date(), calendar: Calendar = .current) -> String {
    let status = item.completed ? ansi.green("[x]") : ansi.dim("[ ]")
    let priVal = eventKitPriorityMarkerValue(item.priority)
    let priStr = (Constants.priorityMarker[priVal]?.isEmpty == false) ? " \(colorPriority(priVal, ansi: ansi))" : ""
    var title = safeDisplay(item.title.isEmpty ? "(untitled)" : item.title)
    var dueStr = fmtDue(item.dueDate.map { AppleEpoch.toTs($0) }, now: now, ansi: ansi,
                        calendar: calendar, allDay: item.allDay)
    let idStr = ansi.dim("EventKit ID: \(safeDisplay(item.eventKitId.isEmpty ? "?" : item.eventKitId))")
    if item.completed {
        title = ansi.dim(ansi.strikethrough(title))
        dueStr = ansi.dim(dueStr)
    }
    var parts = ["\(indent)\(status)\(priStr) \(title)\(dueStr) \(idStr)"]
    if verbose {
        if !item.list.isEmpty {
            parts.append("\(indent)    List: \(safeDisplay(item.list))")
        }
        if let notes = item.notes, !notes.isEmpty {
            parts.append("\(indent)    Notes: \(ansi.dim(String(safeDisplay(notes).prefix(200))))")
        }
        if let url = item.url, !url.isEmpty {
            parts.append("\(indent)    URL: \(ansi.dim(safeDisplay(url)))")
        }
        let summary = recurrenceSummary(item.recurrence ?? [])
        if !summary.isEmpty {
            parts.append("\(indent)    Repeats: \(ansi.magenta(summary))")
        }
        if item.allDay {
            parts.append("\(indent)    All-day: \(ansi.cyan("Yes"))")
        }
    }
    return parts.joined(separator: "\n")
}

/// Port of `print_eventkit_notice` + `output_eventkit_read`'s human branch
/// (remctl:2549-2586). Returns the full rendered text (newline-terminated lines).
public func renderEventKitRead(
    items: [EventKitItemSnapshot], heading: String, emptyMessage: String,
    groupByDay: Bool = false, verbose: Bool = false,
    ansi: Ansi, now: Date = Date(), calendar: Calendar = .current
) -> String {
    var lines: [String] = []
    lines.append(ansi.yellow("EventKit limited read fallback"))
    lines.append(ansi.dim(EventKitRead.idWarning))
    lines.append(ansi.dim("Unavailable in this mode: " + EventKitRead.limitations.dropFirst().joined(separator: ", ")))
    lines.append("")
    lines.append(ansi.bold(heading))
    if items.isEmpty {
        lines.append(emptyMessage)
        return lines.joined(separator: "\n") + "\n"
    }
    if groupByDay {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var groups: [(key: String, label: String, items: [EventKitItemSnapshot])] = []
        for item in items {
            let key: String
            var label: String
            if let due = item.dueDate {
                let comps = calendar.dateComponents([.year, .month, .day], from: due)
                key = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
                let day = calendar.startOfDay(for: due)
                if day == today { label = "Today" }
                else if day == tomorrow { label = "Tomorrow" }
                else {
                    let lf = DateFormatter()
                    lf.calendar = calendar
                    lf.locale = Locale(identifier: "en_US_POSIX")
                    lf.timeZone = calendar.timeZone
                    lf.dateFormat = "EEEE, MMM dd"
                    label = lf.string(from: due)
                }
            } else {
                key = "No due date"
                label = "No due date"
            }
            if let idx = groups.firstIndex(where: { $0.key == key && $0.label == label }) {
                groups[idx].items.append(item)
            } else {
                groups.append((key: key, label: label, items: [item]))
            }
        }
        for group in groups.sorted(by: { ($0.key, $0.label) < ($1.key, $1.label) }) {
            lines.append("\n  \(ansi.bold(group.label)):")
            for item in group.items {
                lines.append(fmtEventKitItem(item, verbose: verbose, indent: "    ", ansi: ansi, now: now, calendar: calendar))
            }
        }
    } else {
        for item in items {
            lines.append(fmtEventKitItem(item, verbose: verbose, indent: "  ", ansi: ansi, now: now, calendar: calendar))
        }
    }
    let n = items.count
    lines.append("\n\(n) reminder\(n == 1 ? "" : "s")")
    return lines.joined(separator: "\n") + "\n"
}
