import Foundation

public struct PrivateResult: Sendable, Equatable {
    public var status: String                 // "updated" | "created" | "deleted" | "error"
    public var fields: [String: JSONValue]    // echoed action-specific keys (id, url, name, subtasks, pinned, ...)
    public var message: String?               // present when status == "error"
    public init(status: String, fields: [String: JSONValue] = [:], message: String? = nil) {
        self.status = status; self.fields = fields; self.message = message
    }
}

/// A subtask spec mirroring Python parse_subtask_specs. All optional except title.
public struct SubtaskSpec: Sendable, Equatable {
    public var title: String
    public var notes: String?
    public var due: String?            // ISO string
    public var allDay: Bool            // date-only `due` text ⇒ the child is all-day
    public var priority: String?       // high/medium/low/none
    public var alarm: String?
    public var recurrence: String?
    public var earlyReminder: String?
    public var urls: [String]
    public var tags: [String]
    public var images: [String]
    public var flagged: Bool?
    public var urgent: Bool?
    public var latitude: Double?
    public var longitude: Double?
    public var locationTitle: String?
    public var radius: Double?
    public var proximity: Int?         // 1=enter, 2=leave
    public init(title: String, notes: String? = nil, due: String? = nil, allDay: Bool = false, priority: String? = nil, alarm: String? = nil, recurrence: String? = nil, earlyReminder: String? = nil, urls: [String] = [], tags: [String] = [], images: [String] = [], flagged: Bool? = nil, urgent: Bool? = nil, latitude: Double? = nil, longitude: Double? = nil, locationTitle: String? = nil, radius: Double? = nil, proximity: Int? = nil) {
        self.title = title; self.notes = notes; self.due = due; self.allDay = allDay; self.priority = priority
        self.alarm = alarm; self.recurrence = recurrence; self.earlyReminder = earlyReminder
        self.urls = urls; self.tags = tags; self.images = images
        self.flagged = flagged; self.urgent = urgent
        self.latitude = latitude; self.longitude = longitude; self.locationTitle = locationTitle
        self.radius = radius; self.proximity = proximity
    }
}

public enum EarlyReminderWrite: Sendable, Equatable {
    case clear(existingIdentifiers: [String])
    case set(unit: Int, count: Int, existingIdentifiers: [String])   // unit 0=min,1=hour,2=day,3=week,4=month; count is negative
}

public struct PrivateLocation: Sendable, Equatable {
    public var title: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var proximity: Int          // 1=enter, 2=leave
    public var address: String?
    public init(title: String, latitude: Double, longitude: Double, radius: Double, proximity: Int, address: String? = nil) {
        self.title = title; self.latitude = latitude; self.longitude = longitude
        self.radius = radius; self.proximity = proximity; self.address = address
    }
}

public struct ListAppearance: Sendable, Equatable {
    public var name: String?
    public var color: String?
    public var symbol: String?
    public var emoji: String?
    public var shouldCategorizeGroceryItems: Bool?
    public var groceryLocaleID: String?
    public var isEmpty: Bool { name == nil && color == nil && symbol == nil && emoji == nil && shouldCategorizeGroceryItems == nil && groceryLocaleID == nil }
    public init(name: String? = nil, color: String? = nil, symbol: String? = nil, emoji: String? = nil, shouldCategorizeGroceryItems: Bool? = nil, groceryLocaleID: String? = nil) {
        self.name = name; self.color = color; self.symbol = symbol; self.emoji = emoji
        self.shouldCategorizeGroceryItems = shouldCategorizeGroceryItems; self.groceryLocaleID = groceryLocaleID
    }
}

/// The private Reminders boundary. `id` is the reminder's ZCKIDENTIFIER.
public protocol PrivateWriter {
    // reminder-scoped (keyed by reminder ckIdentifier)
    func setFlagged(id: String, flagged: Bool) async throws -> PrivateResult
    func addPrivateMetadata(id: String, urls: [String], tags: [String]) async throws -> PrivateResult
    /// Replaces the reminder's synced tags with exactly `tags`; an empty array removes them all.
    func setTags(id: String, tags: [String]) async throws -> PrivateResult
    func assignSection(id: String, sectionId: String) async throws -> PrivateResult
    /// `existingSectionIds` are the target list's current section CKIDs in display order; the new
    /// section is appended to them so creating a section does not wipe the existing ordering.
    func addSectionAndAssign(id: String, name: String, existingSectionIds: [String]) async throws -> PrivateResult
    func assignSharee(id: String, assigneeId: String, originatorId: String) async throws -> PrivateResult
    func clearAssignment(id: String) async throws -> PrivateResult
    func addSubtasks(id: String, subtasks: [SubtaskSpec]) async throws -> PrivateResult
    func addAttachments(id: String, images: [String]) async throws -> PrivateResult
    func setUrgent(id: String, urgent: Bool) async throws -> PrivateResult
    func setEarlyReminder(id: String, spec: EarlyReminderWrite) async throws -> PrivateResult
    func addLocationAlarm(id: String, location: PrivateLocation) async throws -> PrivateResult
    func categorizeGroceryItems(listId: String, reminderIds: [String]) async throws -> PrivateResult
    /// Copies a reminder (and the given subtasks) into another list. ReminderKit is the only
    /// write path that can carry a subtask tree across a list boundary (upstream ed5e982).
    func cloneReminderTree(id: String, listId: String, childIds: [String]) async throws -> PrivateResult
    // list / smart-list / template scoped
    func setListAppearance(listId: String, appearance: ListAppearance) async throws -> PrivateResult
    func setListPinned(listId: String, pinned: Bool) async throws -> PrivateResult
    /// `isCustom` tells the helper which ReminderKit fetch to use: custom smart lists and built-in
    /// smart lists have distinct object IDs, so the wrong fetch returns ReminderKit error -3000.
    func setSmartListPinned(smartListId: String, pinned: Bool, isCustom: Bool) async throws -> PrivateResult
    func createList(name: String, appearance: ListAppearance) async throws -> PrivateResult
    func createSmartList(name: String, filterData: Data, appearance: ListAppearance) async throws -> PrivateResult
    func updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance) async throws -> PrivateResult
    func deleteSmartList(smartListId: String) async throws -> PrivateResult
    func createTemplate(name: String, sourceListId: String, includeCompleted: Bool) async throws -> PrivateResult
    func applyTemplate(templateId: String) async throws -> PrivateResult
    func deleteTemplate(templateId: String) async throws -> PrivateResult
    // list sections (keyed by list / section ckIdentifier)
    /// `existingSectionIds` is the list's current section order; the new section is appended to it
    /// because Reminders replaces the whole ordering on save.
    func createSection(listId: String, name: String, existingSectionIds: [String]) async throws -> PrivateResult
    func renameSection(sectionId: String, name: String) async throws -> PrivateResult
    func deleteSection(sectionId: String) async throws -> PrivateResult
    // list groups (keyed by list / group ckIdentifier)
    func createGroup(name: String) async throws -> PrivateResult
    /// Moves a list into `groupId`, or to the top level when it is nil. Only the container changes.
    func setListParentGroup(listId: String, groupId: String?) async throws -> PrivateResult
    func deleteGroup(groupId: String) async throws -> PrivateResult
    // reminder ordering (keyed by reminder / list / smart-list ckIdentifier)
    /// Places a reminder `position` (before/after `anchorId`, or first/last) in its list's ordering.
    func moveReminderInList(id: String, listId: String, position: String, anchorId: String?) async throws -> PrivateResult
    /// Replaces an unsectioned custom smart list's manual order with `topLevelElementIds`.
    func setSmartListManualOrder(id: String, smartListId: String, manualOrderingId: String,
                                 topLevelElementIds: [String]) async throws -> PrivateResult
    /// Nests a reminder under `parentId` (the top level when nil) at `position` (before/after
    /// `anchorId`, or `append`). The reminder keeps its identifier.
    func moveReminderInHierarchy(id: String, listId: String, parentId: String?, position: String,
                                 anchorId: String?) async throws -> PrivateResult
}
