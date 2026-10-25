import Foundation
import EventKit

// ──────────────────────────────────────────────────────────────────────────────
// Live EventKit fetch for --via-eventkit — port of the bridge `runLimitedEventKitRead`
// (upstream 391b1c9), in-process. Works WITHOUT Full Disk Access: it never opens the
// Reminders SQLite store, only the EventKit API (TCC Reminders permission).
//
// NOTE: not exercised in CI — needs a real Reminders store + granted TCC permission,
// like EventKitWriter. The pure shaping/rendering layer lives in EventKitRead.swift.
// ──────────────────────────────────────────────────────────────────────────────

public final class EventKitReader {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    private func requestAccess() async throws {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw EventKitReadError("EventKit access error: \(error.localizedDescription)",
                                    code: "eventkit_read_failed", exitCode: 1)
        }
        if !granted {
            throw EventKitReadError("Reminders access not granted",
                                    code: "eventkit_read_failed", exitCode: 1)
        }
    }

    /// Scope the read to iCloud reminder lists: an unnamed list used to query every source,
    /// and a title match alone cannot disambiguate duplicates (upstream c0db904, e6d2a7e).
    private func calendars(listName: String?) throws -> [EKCalendar] {
        let all = store.calendars(for: .reminder)
        let descriptors = all.map {
            ReminderCalendarDescriptor(
                identifier: $0.calendarIdentifier, title: $0.title,
                source: ReminderSourceDescriptor(
                    identifier: $0.source?.sourceIdentifier ?? "", title: $0.source?.title ?? "",
                    isCalDAV: $0.source?.sourceType == .calDAV))
        }
        do {
            let wanted = try ListTargeting.readCalendars(
                in: descriptors, listName: listName, providers: AccountProviders.shared)
            let wantedIdentifiers = Set(wanted.map(\.identifier))
            return all.filter { wantedIdentifiers.contains($0.calendarIdentifier) }
        } catch let e as ListTargetingError {
            throw EventKitReadError(e.message, code: "eventkit_read_failed", exitCode: 1)
        }
    }

    /// Bridge `fetchReminders`: synchronous fetch with a 30s timeout + cancel.
    private func fetchReminders(matching predicate: NSPredicate) throws -> [EKReminder] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EKReminder] = []
        let fetchId = store.fetchReminders(matching: predicate) { reminders in
            result = reminders ?? []
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            store.cancelFetchRequest(fetchId)
            throw EventKitReadError("EventKit read timed out", code: "eventkit_read_failed", exitCode: 1)
        }
        return result
    }

    /// Bridge `dateFromComponents`: date + all-day flag (no hour/minute/second).
    private func dateAndAllDay(_ components: DateComponents?) -> (Date?, Bool) {
        guard var components else { return (nil, false) }
        let allDay = components.hour == nil && components.minute == nil && components.second == nil
        if components.calendar == nil { components.calendar = Calendar.current }
        return (components.date, allDay)
    }

    private func alarmJSON(_ alarm: EKAlarm) -> JSONValue {
        if let absolute = alarm.absoluteDate {
            return .object([
                ("type", .string("absolute")),
                ("date", .string(isoLocalDateTime(appleSeconds: AppleEpoch.toTs(absolute)))),
            ])
        }
        if alarm.structuredLocation != nil {
            return .object([
                ("type", .string("location")),
                ("proximity", .string(alarm.proximity == .leave ? "leaving" : "arriving")),
            ])
        }
        return .object([
            ("type", .string("relative")),
            ("relativeOffset", .double(alarm.relativeOffset)),
            ("relativeOffsetMinutes", .int(Int(alarm.relativeOffset / 60.0))),
        ])
    }

    private func recurrenceJSON(_ rule: EKRecurrenceRule) -> [(String, JSONValue)] {
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        var pairs: [(String, JSONValue)] = [
            ("frequency", .string(frequency)),
            ("interval", .int(rule.interval)),
        ]
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            pairs.append(("daysOfWeek", .array(days.map { .int($0.dayOfTheWeek.rawValue) })))
        }
        if let days = rule.daysOfTheMonth, !days.isEmpty {
            pairs.append(("daysOfMonth", .array(days.map { .int($0.intValue) })))
        }
        return pairs
    }

    private func snapshot(_ reminder: EKReminder) -> EventKitItemSnapshot {
        let (due, allDay) = dateAndAllDay(reminder.dueDateComponents)
        return EventKitItemSnapshot(
            eventKitId: reminder.calendarItemIdentifier,
            externalId: reminder.calendarItemExternalIdentifier,
            title: reminder.title ?? "",
            list: reminder.calendar?.title ?? "",
            completed: reminder.isCompleted,
            priority: Int(reminder.priority),
            notes: reminder.notes,
            url: reminder.url?.absoluteString,
            dueDate: due,
            allDay: allDay,
            createdDate: reminder.creationDate,
            completionDate: reminder.completionDate,
            alarms: (reminder.alarms ?? []).map { alarmJSON($0) },
            recurrence: (reminder.recurrenceRules?.first).map { recurrenceJSON($0) })
    }

    private func containsQuery(_ reminder: EKReminder, _ query: String) -> Bool {
        EventKitReader.matchesQuery(title: reminder.title, notes: reminder.notes,
                                    url: reminder.url?.absoluteString, query: query)
    }

    /// Search covers the saved rich link too, so a URL a user pasted is findable (upstream b8b601c).
    static func matchesQuery(title: String?, notes: String?, url: String?, query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return [title, notes, url].contains { ($0 ?? "").range(of: query, options: options) != nil }
    }

    /// Due date ascending, undated last, then title. Comparator over precomputed keys.
    static func sortsBefore(_ left: (due: Date?, title: String), _ right: (due: Date?, title: String)) -> Bool {
        switch (left.due, right.due) {
        case let (l?, r?) where l != r: return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return left.title < right.title
        }
    }

    /// Port of `runLimitedEventKitRead`: modes show/search/today/upcoming.
    public func read(
        mode: String, list: String? = nil, query: String? = nil, completed: Bool = false,
        days: Int = 7, includeOverdue: Bool = true, limit: Int = 500
    ) async throws -> [EventKitItemSnapshot] {
        try await requestAccess()
        let calendars = try calendars(listName: list)
        let cappedLimit = max(1, min(limit, 1000))
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            throw EventKitReadError("Invalid date range", code: "eventkit_read_failed", exitCode: 1)
        }
        var reminders: [EKReminder]

        switch mode {
        case "show":
            reminders = try fetchReminders(matching: store.predicateForReminders(in: calendars))
            if !completed { reminders = reminders.filter { !$0.isCompleted } }
        case "search":
            guard let query, !query.isEmpty else {
                throw EventKitReadError("query is required", code: "eventkit_read_failed", exitCode: 1)
            }
            reminders = try fetchReminders(matching: store.predicateForReminders(in: calendars))
            if !completed { reminders = reminders.filter { !$0.isCompleted } }
            reminders = reminders.filter { containsQuery($0, query) }
        case "today":
            let start = includeOverdue ? nil : startOfToday
            reminders = try fetchReminders(matching: store.predicateForIncompleteReminders(
                withDueDateStarting: start, ending: startOfTomorrow, calendars: calendars))
        case "upcoming":
            let clampedDays = max(1, min(days, 3650))
            guard let end = calendar.date(byAdding: .day, value: clampedDays + 1, to: startOfToday) else {
                throw EventKitReadError("Invalid upcoming range", code: "eventkit_read_failed", exitCode: 1)
            }
            reminders = try fetchReminders(matching: store.predicateForIncompleteReminders(
                withDueDateStarting: startOfToday, ending: end, calendars: calendars))
        default:
            throw EventKitReadError("Unsupported EventKit read mode: \(mode)", code: "eventkit_read_failed", exitCode: 1)
        }

        // Convert date components once per reminder, rather than on each comparison (upstream b749bbf).
        var sortable = reminders.map {
            (reminder: $0, key: (due: dateAndAllDay($0.dueDateComponents).0, title: $0.title ?? ""))
        }
        sortable.sort { EventKitReader.sortsBefore($0.key, $1.key) }
        return sortable.prefix(cappedLimit).map { snapshot($0.reminder) }
    }
}

/// Command glue: validate → fetch → emit (JSON wrapper or human render), exiting on
/// EventKitReadError with its code-specific exit status. Each read command calls this
/// INSTEAD of Dispatch.runRead, so --via-eventkit never opens the SQLite store.
enum EventKitReadCLI {
    static func run(
        mode: String, listId: Int? = nil, listName: String? = nil, requiresListName: Bool = false,
        query: String? = nil, completed: Bool = false, days: Int = 7, includeOverdue: Bool = true,
        opts: ReadDisplayOptions, heading: String, emptyMessage: String, groupByDay: Bool = false
    ) async {
        let json = opts.effectiveJSON
        do {
            try validateEventKitReadArgs(listId: listId, formatIsTable: opts.format == .table,
                                         requiresListName: requiresListName, listName: listName)
            let items = try await EventKitReader().read(
                mode: mode, list: listName, query: query, completed: completed,
                days: days, includeOverdue: includeOverdue)
            if json {
                Dispatch.printJSON(eventKitReadPayloadJSON(mode: mode, items: items), ensureAscii: false)
            } else {
                print(renderEventKitRead(items: items, heading: heading, emptyMessage: emptyMessage,
                                         groupByDay: groupByDay, verbose: opts.verbose, ansi: opts.ansi()),
                      terminator: "")
            }
        } catch let e as EventKitReadError {
            FileHandle.standardError.write(Data(eventKitReadErrorText(e, json: json).utf8))
            exit(e.exitCode)
        } catch {
            let e = EventKitReadError("\(error)", code: "eventkit_read_failed", exitCode: 1)
            FileHandle.standardError.write(Data(eventKitReadErrorText(e, json: json).utf8))
            exit(1)
        }
    }
}
