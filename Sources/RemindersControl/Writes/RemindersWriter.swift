import Foundation

/// Due-date intent on a write: set to a date, or explicitly clear. nil (absent) = leave unchanged.
public enum DueWrite: Equatable { case set(Date); case clear }

public enum AlarmWrite: Equatable {
    case relativeOffset(TimeInterval)   // negative = before due (e.g. -900 for 15m before)
    case absolute(Date)
    case clear                          // remove all alarms
}

public struct RecurrenceWrite: Equatable {
    public var frequency: String        // "daily"|"weekly"|"monthly"|"yearly"
    public var interval: Int?
    public var daysOfWeek: [Int]?       // 1=Sun..7=Sat
    public var daysOfMonth: [Int]?
    public var end: Date?
    public init(frequency: String, interval: Int? = nil, daysOfWeek: [Int]? = nil, daysOfMonth: [Int]? = nil, end: Date? = nil) {
        self.frequency = frequency; self.interval = interval; self.daysOfWeek = daysOfWeek; self.daysOfMonth = daysOfMonth; self.end = end
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
    public var list: String?             // target list NAME (EventKit findList by title)
    public var due: DueWrite?
    public var priority: Int?            // 0/1/5/9
    public var notes: String?
    public var url: String?              // appended to notes (rich URL is Phase 3)
    public var flagged: Bool?            // EventKit priority-proxy (real flag is Phase 3)
    public var recurrence: RecurrenceWrite?
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
    func update(id: String, _ write: ReminderWrite, clearDue: Bool) async throws -> WriteResult
    func delete(id: String) async throws -> WriteResult
    func complete(id: String) async throws -> WriteResult
    func uncomplete(id: String) async throws -> WriteResult
    func createList(title: String, color: String?) async throws -> WriteResult
    func renameList(currentTitle: String, newTitle: String) async throws -> WriteResult
    func deleteList(title: String) async throws -> WriteResult
}
