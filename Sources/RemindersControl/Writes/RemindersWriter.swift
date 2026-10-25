import Foundation

/// Due-date intent on a write. nil (the ReminderWrite.due being nil) = leave unchanged; .set = set; .clear = remove the due date (the canonical clear signal; mirrors the bridge's dueExplicitlyNull). EventKitWriter maps .clear -> reminder.dueDateComponents = nil.
public enum DueWrite: Equatable { case set(Date); case clear }

public enum AlarmWrite: Equatable {
    case relativeOffset(TimeInterval)   // negative = before due (e.g. -900 for 15m before)
    case absolute(Date)
    case clear                          // remove all alarms
}

/// An EventKit recurrence rule. The CLI string grammar only ever fills frequency/interval/
/// daysOfWeek/daysOfMonth; the remaining fields exist so an exported `recurrence` object
/// (`ReminderSerializer.recurrenceFromRow`) round-trips through `import` and subtask JSON.
public struct RecurrenceWrite: Equatable {
    public var frequency: String        // "daily"|"weekly"|"monthly"|"yearly"
    public var interval: Int?
    public var daysOfWeek: [Int]?       // 1=Sun..7=Sat
    public var weekNumbers: [Int]?      // parallel to daysOfWeek; 0 = unpinned, -1 = last
    public var daysOfMonth: [Int]?
    public var monthsOfYear: [Int]?
    public var daysOfYear: [Int]?
    public var weeksOfYear: [Int]?
    public var setPositions: [Int]?
    public var count: Int?              // occurrence-count end; mutually exclusive with `end`
    public var end: Date?
    public init(frequency: String, interval: Int? = nil, daysOfWeek: [Int]? = nil,
                weekNumbers: [Int]? = nil, daysOfMonth: [Int]? = nil, monthsOfYear: [Int]? = nil,
                daysOfYear: [Int]? = nil, weeksOfYear: [Int]? = nil, setPositions: [Int]? = nil,
                count: Int? = nil, end: Date? = nil) {
        self.frequency = frequency; self.interval = interval; self.daysOfWeek = daysOfWeek
        self.weekNumbers = weekNumbers; self.daysOfMonth = daysOfMonth; self.monthsOfYear = monthsOfYear
        self.daysOfYear = daysOfYear; self.weeksOfYear = weeksOfYear; self.setPositions = setPositions
        self.count = count; self.end = end
    }
}

public struct LocationAlarmWrite: Equatable {
    public var title: String?
    public var latitude: Double
    public var longitude: Double
    public var radius: Double            // meters
    public var proximity: String         // "arriving"/"enter" or "leaving"/"leave"
    public init(title: String?, latitude: Double, longitude: Double, radius: Double, proximity: String) {
        self.title = title; self.latitude = latitude; self.longitude = longitude; self.radius = radius; self.proximity = proximity
    }
}

/// Mirrors the bridge `Command` (EventKit-settable fields). nil = leave unchanged.
public struct ReminderWrite: Equatable {
    public var title: String?
    public var list: String?             // target list NAME (fallback when the CKID cannot be matched)
    public var listId: String?           // target list CKID (ZCKIDENTIFIER) — matched first, so duplicate titles resolve correctly
    public var due: DueWrite?
    public var allDay: Bool?             // with .set due: store date-only components (mirrors bridge Command.allDay)
    public var priority: Int?            // 0/1/5/9
    public var notes: String?
    public var url: String?              // appended to notes (rich URL is Phase 3)
    public var recurrence: RecurrenceWrite?
    public var clearRecurrence = false   // remove the repeat rule (bridge `clearRecurrence`)
    public var alarm: AlarmWrite?
    public var location: LocationAlarmWrite?
    public init() {}
}

public struct WriteResult: Equatable {
    public var status: String            // "created"/"updated"/"deleted"/"completed"/...
    public var id: String?               // EventKit calendarItemIdentifier (for create/createList)
    public var title: String?
    public init(status: String, id: String? = nil, title: String? = nil) { self.status = status; self.id = id; self.title = title }
}

public struct AuthSummary: Equatable {
    public var calendarCount: Int
    public var defaultList: String
    public init(calendarCount: Int, defaultList: String) { self.calendarCount = calendarCount; self.defaultList = defaultList }
}

/// A write that failed with a user-facing message + exit code (mirrors fail()/fail_invalid_due_date).
/// `message` is WITHOUT the "Error: " prefix; the command shell adds it.
public struct WriteError: Error, Equatable {
    public let message: String
    public let exitCode: Int32
    public init(_ message: String, exitCode: Int32 = 1) { self.message = message; self.exitCode = exitCode }
}

/// The EventKit boundary. `id` is the reminder's ZCKIDENTIFIER / EventKit calendarItemIdentifier.
public protocol RemindersWriter {
    func authorize() async throws -> AuthSummary
    func create(_ write: ReminderWrite) async throws -> WriteResult
    func update(id: String, _ write: ReminderWrite) async throws -> WriteResult
    func delete(id: String) async throws -> WriteResult
    func complete(id: String, completionDate: Date?) async throws -> WriteResult
    func uncomplete(id: String) async throws -> WriteResult
    func createList(title: String, color: String?) async throws -> WriteResult
    func renameList(currentTitle: String, listId: String?, newTitle: String) async throws -> WriteResult
    func deleteList(title: String, listId: String?) async throws -> WriteResult
}

public extension RemindersWriter {
    /// Complete with the default completion date (now).
    func complete(id: String) async throws -> WriteResult {
        try await complete(id: id, completionDate: nil)
    }
}
