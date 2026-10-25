import Foundation
import EventKit
import CoreLocation

/// In-process EventKit backing for `RemindersWriter`. Wraps a single `EKEventStore`
/// and ports the EventKit logic from the standalone `remctl-bridge.swift` helper
/// (which previously ran as an out-of-process subprocess). Behavior and the
/// load-bearing comments are preserved verbatim from that bridge.
///
/// NOTE: This type cannot be exercised in CI — it needs a real Reminders store and
/// a granted TCC permission. It is verified manually (W13). The unit-testable seam
/// is `colorForName` (pure string→CGColor), covered in EventKitWriterTests.
public final class EventKitWriter: RemindersWriter {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: - Authorization

    public func authorize() async throws -> AuthSummary {
        try await requestAccess()
        return AuthSummary(calendarCount: store.calendars(for: .reminder).count,
                           defaultList: store.defaultCalendarForNewReminders()?.title ?? "")
    }

    /// Requests full Reminders access. EventKit caches the authorization, so calling
    /// this before every action (as the bridge did) is idempotent and cheap.
    private func requestAccess() async throws {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw WriteError("EventKit access error: \(error.localizedDescription)")
        }
        if !granted { throw WriteError("Reminders access not granted") }
    }

    // MARK: - Lookups

    private func findReminder(id: String) throws -> EKReminder {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw WriteError("Reminder not found for id: \(id)")
        }
        return item
    }

    private func findList(name: String) throws -> EKCalendar {
        guard let cal = store.calendars(for: .reminder).first(where: { $0.title == name }) else {
            throw WriteError("List not found: \(name)")
        }
        return cal
    }

    // MARK: - Recurrence

    /// Translate a validated `RecurrenceWrite` into an EventKit rule. Pure (no EventKit state
    /// beyond the rule it builds), so it is unit-testable alongside `colorForName`.
    /// Port of the bridge's `buildRecurrenceRule` (upstream c84fbca, 98efe89).
    func buildRecurrenceRule(_ spec: RecurrenceWrite) -> EKRecurrenceRule? {
        let freq: EKRecurrenceFrequency
        switch spec.frequency {
        case "daily":   freq = .daily
        case "weekly":  freq = .weekly
        case "monthly": freq = .monthly
        case "yearly":  freq = .yearly
        default: return nil
        }

        let interval = spec.interval ?? 1
        guard interval > 0 else { return nil }

        var daysOfWeek: [EKRecurrenceDayOfWeek]?
        if let days = spec.daysOfWeek {
            // Input: 1=Sun, 2=Mon ... 7=Sat → EKWeekday raw values match
            guard !days.isEmpty, days.allSatisfy({ 1...7 ~= $0 }) else { return nil }
            // Week numbers pin a weekday to the Nth week of the period (4 = 4th Friday,
            // -1 = last Friday); 0 means unpinned. Validate here: EKRecurrenceDayOfWeek
            // raises an uncatchable NSException on an out-of-range or wrong-frequency week
            // number, so a bad value must never reach it.
            var weekNumbers: [Int]?
            if let numbers = spec.weekNumbers, !numbers.isEmpty {
                guard numbers.count == days.count else { return nil }
                let bounds: ClosedRange<Int>
                switch freq {
                case .monthly: bounds = -5...5
                case .yearly:  bounds = -53...53
                default:       bounds = 0...0   // daily/weekly accept no pinning at all
                }
                guard numbers.allSatisfy({ bounds ~= $0 }) else { return nil }
                weekNumbers = numbers
            }
            daysOfWeek = zip(days, weekNumbers ?? Array(repeating: 0, count: days.count)).map { day, number in
                let weekday = EKWeekday(rawValue: day)!
                return number == 0 ? EKRecurrenceDayOfWeek(weekday)
                                   : EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: number)
            }
        }

        var daysOfMonth: [NSNumber]?
        if let days = spec.daysOfMonth {
            guard !days.isEmpty, days.allSatisfy({ $0 != 0 && -31...31 ~= $0 }) else { return nil }
            daysOfMonth = days.map { NSNumber(value: $0) }
        }

        for (values, bounds) in [(spec.monthsOfYear, 1...12), (spec.daysOfYear, -366...366),
                                 (spec.weeksOfYear, -53...53), (spec.setPositions, -366...366)] {
            guard let values else { continue }
            guard !values.isEmpty, values.allSatisfy({ $0 != 0 && bounds ~= $0 }) else { return nil }
        }

        var end: EKRecurrenceEnd?
        if let endDate = spec.end {
            guard spec.count == nil else { return nil }
            end = EKRecurrenceEnd(end: endDate)
        } else if let count = spec.count {
            guard count > 0 else { return nil }
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(
            recurrenceWith: freq,
            interval: interval,
            daysOfTheWeek: daysOfWeek,
            daysOfTheMonth: daysOfMonth,
            monthsOfTheYear: spec.monthsOfYear?.map { NSNumber(value: $0) },
            weeksOfTheYear: spec.weeksOfYear?.map { NSNumber(value: $0) },
            daysOfTheYear: spec.daysOfYear?.map { NSNumber(value: $0) },
            setPositions: spec.setPositions?.map { NSNumber(value: $0) },
            end: end
        )
    }

    // MARK: - Color mapping

    /// Maps a named color to a CGColor for list creation. Pure function (no EventKit
    /// state), so it is the one unit-testable seam in this class.
    func colorForName(_ name: String) -> CGColor? {
        let map: [String: (CGFloat, CGFloat, CGFloat)] = [
            "red":    (1.0, 0.23, 0.19),
            "orange": (1.0, 0.58, 0.0),
            "yellow": (1.0, 0.8, 0.0),
            "green":  (0.3, 0.85, 0.39),
            "blue":   (0.0, 0.48, 1.0),
            "purple": (0.69, 0.32, 0.87),
            "brown":  (0.64, 0.52, 0.37),
            "cyan":   (0.35, 0.78, 0.98),
        ]
        guard let (r, g, b) = map[name.lowercased()] else { return nil }
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Field mapping

    private func applyFields(_ reminder: EKReminder, _ write: ReminderWrite) throws {
        if let t = write.title { reminder.title = t }

        if let list = write.list {
            reminder.calendar = try findList(name: list)
        }

        // due: .set(date) → set date, .clear → remove.
        // Set dueDateComponents WITHOUT .timeZone in the component set AND set
        // reminder.timeZone explicitly — this mirrors Reminders.app's save path and
        // produces a changedKeys set CloudKit accepts as a full dueDate update. The
        // previous variant embedded .timeZone in the components + cleared
        // startDateComponents; that produced a CKRecord push that remindd logged as
        // successful but CloudKit silently ignored the dueDate field
        // (observed 2026-04-17, verified against AppleScript-authored pushes).
        if case .set(let date) = write.due {
            if write.allDay == true {
                // All-day reminders store date-only components (no hour/minute/second),
                // which is how Reminders.app encodes "all day" — a midnight timed
                // component set is NOT equivalent.
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day], from: date)
            } else {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: date)
            }
            reminder.timeZone = TimeZone.current
        } else if case .clear = write.due {
            reminder.dueDateComponents = nil
        }

        if let p = write.priority {
            guard 0...9 ~= p else { throw WriteError("Invalid priority") }
            reminder.priority = p
        }

        // Apply notes first, then URL.
        // EKReminder.url (EventKit) does NOT map to the ZICSURL field that Reminders.app
        // displays — that's a private ReminderKit property. We can read ZICSURL from CoreData
        // but cannot write it via public EventKit APIs. As a fallback, append the URL to the
        // notes field so it appears as a tappable link in the reminder detail view.
        if let n = write.notes { reminder.notes = n }
        if let u = write.url {
            if let existing = reminder.notes, !existing.isEmpty {
                reminder.notes = existing + "\n\n" + u
            } else {
                reminder.notes = u
            }
        }

        if let spec = write.recurrence {
            guard let rule = buildRecurrenceRule(spec) else { throw WriteError("Invalid recurrence") }
            reminder.recurrenceRules = [rule]
        }

        if let alarm = write.alarm {
            switch alarm {
            case .relativeOffset(let offset):
                reminder.alarms = [EKAlarm(relativeOffset: offset)]
            case .absolute(let date):
                reminder.alarms = [EKAlarm(absoluteDate: date)]
            case .clear:
                reminder.alarms = []
            }
        }

        if let loc = write.location {
            guard (-90.0...90.0).contains(loc.latitude), (-180.0...180.0).contains(loc.longitude) else {
                throw WriteError("Invalid location coordinates")
            }
            guard loc.radius > 0, loc.radius <= 100_000 else { throw WriteError("Invalid location radius") }
            let location = EKStructuredLocation(title: loc.title ?? "Location")
            location.geoLocation = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            location.radius = loc.radius
            let alarm = EKAlarm()
            alarm.structuredLocation = location
            guard ["enter", "arriving", "leave", "leaving"].contains(loc.proximity) else {
                throw WriteError("Invalid location proximity")
            }
            let proximityValue = (loc.proximity == "leaving" || loc.proximity == "leave")
                ? EKAlarmProximity.leave
                : EKAlarmProximity.enter
            alarm.proximity = proximityValue
            var alarms = reminder.alarms ?? []
            alarms.append(alarm)
            reminder.alarms = alarms
        }
    }

    // MARK: - Reminder actions

    public func create(_ write: ReminderWrite) async throws -> WriteResult {
        try await requestAccess()
        guard let title = write.title, !title.isEmpty else {
            throw WriteError("title is required for create")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let list = write.list {
            reminder.calendar = try findList(name: list)
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        try applyFields(reminder, write)
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw WriteError("Save failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "created", id: reminder.calendarItemIdentifier, title: reminder.title ?? "")
    }

    public func update(id: String, _ write: ReminderWrite) async throws -> WriteResult {
        try await requestAccess()
        let reminder = try findReminder(id: id)
        try applyFields(reminder, write)
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw WriteError("Update failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "updated", id: id)
    }

    public func delete(id: String) async throws -> WriteResult {
        try await requestAccess()
        let reminder = try findReminder(id: id)
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw WriteError("Delete failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "deleted", id: id)
    }

    public func complete(id: String, completionDate: Date?) async throws -> WriteResult {
        try await requestAccess()
        let reminder = try findReminder(id: id)
        reminder.isCompleted = true
        // Explicit completion date must be set AFTER isCompleted — setting isCompleted
        // stamps "now", which would overwrite a date assigned first.
        if let completionDate { reminder.completionDate = completionDate }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw WriteError("Complete failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "completed", id: id)
    }

    public func uncomplete(id: String) async throws -> WriteResult {
        try await requestAccess()
        let reminder = try findReminder(id: id)
        reminder.isCompleted = false
        reminder.completionDate = nil
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw WriteError("Uncomplete failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "uncompleted", id: id)
    }

    // MARK: - List actions

    public func createList(title: String, color: String?) async throws -> WriteResult {
        try await requestAccess()
        guard !title.isEmpty else { throw WriteError("title is required for create_list") }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = title
        // Use the local/iCloud source for reminders
        guard let source = store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw WriteError("No suitable calendar source found")
        }
        cal.source = source
        if let colorName = color, let cg = colorForName(colorName) {
            cal.cgColor = cg
        }
        do {
            try store.saveCalendar(cal, commit: true)
        } catch {
            throw WriteError("Create list failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "created", id: cal.calendarIdentifier, title: cal.title)
    }

    public func renameList(currentTitle: String, newTitle: String) async throws -> WriteResult {
        try await requestAccess()
        let cal = try findList(name: currentTitle)
        cal.title = newTitle
        do {
            try store.saveCalendar(cal, commit: true)
        } catch {
            throw WriteError("Rename list failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "renamed", id: cal.calendarIdentifier, title: cal.title)
    }

    public func deleteList(title: String) async throws -> WriteResult {
        try await requestAccess()
        let cal = try findList(name: title)
        do {
            try store.removeCalendar(cal, commit: true)
        } catch {
            throw WriteError("Delete list failed: \(error.localizedDescription)")
        }
        return WriteResult(status: "deleted", title: title)
    }
}
