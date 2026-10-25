import Foundation
@testable import RemindersControl

final class MockPrivateWriter: PrivateWriter, @unchecked Sendable {
    enum Call: Equatable {
        case setFlagged(id: String, flagged: Bool)
        case addPrivateMetadata(id: String, urls: [String], tags: [String])
        case setTags(id: String, tags: [String])
        case assignSection(id: String, sectionId: String)
        case assignSharee(id: String, assigneeId: String, originatorId: String)
        case clearAssignment(id: String)
        case addSectionAndAssign(id: String, name: String, existingSectionIds: [String])
        case addSubtasks(id: String, subtasks: [SubtaskSpec])
        case addAttachments(id: String, images: [String])
        case setUrgent(id: String, urgent: Bool)
        case setEarlyReminder(id: String, spec: EarlyReminderWrite)
        case addLocationAlarm(id: String, location: PrivateLocation)
        case categorizeGroceryItems(listId: String, reminderIds: [String])
        case cloneReminderTree(id: String, listId: String, childIds: [String])
        case setListAppearance(listId: String, appearance: ListAppearance)
        case setListPinned(listId: String, pinned: Bool)
        case setSmartListPinned(smartListId: String, pinned: Bool, isCustom: Bool)
        case createList(name: String, appearance: ListAppearance)
        case createSmartList(name: String, filterData: Data, appearance: ListAppearance)
        case updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance)
        case deleteSmartList(smartListId: String)
        case createTemplate(name: String, sourceListId: String, includeCompleted: Bool)
        case applyTemplate(templateId: String)
        case deleteTemplate(templateId: String)
        case createSection(listId: String, name: String, existingSectionIds: [String])
        case renameSection(sectionId: String, name: String)
        case deleteSection(sectionId: String)
        case createGroup(name: String)
        case setListParentGroup(listId: String, groupId: String?)
        case deleteGroup(groupId: String)
        case moveReminderInList(id: String, listId: String, position: String, anchorId: String?)
        case setSmartListManualOrder(id: String, smartListId: String, manualOrderingId: String, topLevelElementIds: [String])
        case moveReminderInHierarchy(id: String, listId: String, parentId: String?, position: String, anchorId: String?)
    }
    private(set) var calls: [Call] = []
    var result = PrivateResult(status: "updated")
    /// Per-method result override for `addSubtasks` so tests can return child {id,title,url} entries
    /// (P13 pairs each created child to its spec via `fields["subtasks"]`).
    var subtasksResult: PrivateResult?
    /// Per-method result override for `categorizeGroceryItems` (P14) so tests can simulate the
    /// helper returning an error/non-updated status independently of the shared `result`.
    var groceryResult: PrivateResult?
    /// Per-method result override for `cloneReminderTree` so a list-move test can return the
    /// cloned reminder's `newId` without disturbing the shared `result`.
    var cloneResult: PrivateResult?
    /// Per-method result override for `setUrgent` so tests can fail ONE step in the middle of the
    /// fan-out (the partial-failure path) while the earlier steps still succeed.
    var urgentResult: PrivateResult?
    var throwError: Error?
    /// Runs after each call is recorded, so a test can apply the write to its fixture store and
    /// let the command's readback verification see it.
    var onCall: ((Call) -> Void)?
    /// Per-call reply for the section, group, and ordering actions; nil falls back to `result`.
    var reply: ((Call) -> PrivateResult?)?

    private func resultOr(_ status: String) throws -> PrivateResult {
        if let e = throwError { throw e }
        return result
    }

    func setFlagged(id: String, flagged: Bool) async throws -> PrivateResult { calls.append(.setFlagged(id: id, flagged: flagged)); return try resultOr("updated") }
    func addPrivateMetadata(id: String, urls: [String], tags: [String]) async throws -> PrivateResult { calls.append(.addPrivateMetadata(id: id, urls: urls, tags: tags)); return try resultOr("updated") }
    func setTags(id: String, tags: [String]) async throws -> PrivateResult { calls.append(.setTags(id: id, tags: tags)); return try resultOr("updated") }
    func assignSection(id: String, sectionId: String) async throws -> PrivateResult { try record(.assignSection(id: id, sectionId: sectionId)) }
    func assignSharee(id: String, assigneeId: String, originatorId: String) async throws -> PrivateResult { calls.append(.assignSharee(id: id, assigneeId: assigneeId, originatorId: originatorId)); return try resultOr("updated") }
    func clearAssignment(id: String) async throws -> PrivateResult { calls.append(.clearAssignment(id: id)); return try resultOr("updated") }
    func addSectionAndAssign(id: String, name: String, existingSectionIds: [String]) async throws -> PrivateResult { calls.append(.addSectionAndAssign(id: id, name: name, existingSectionIds: existingSectionIds)); return try resultOr("updated") }
    func addSubtasks(id: String, subtasks: [SubtaskSpec]) async throws -> PrivateResult { calls.append(.addSubtasks(id: id, subtasks: subtasks)); if let e = throwError { throw e }; return subtasksResult ?? result }
    func addAttachments(id: String, images: [String]) async throws -> PrivateResult { calls.append(.addAttachments(id: id, images: images)); return try resultOr("updated") }
    func setUrgent(id: String, urgent: Bool) async throws -> PrivateResult { calls.append(.setUrgent(id: id, urgent: urgent)); if let e = throwError { throw e }; return urgentResult ?? result }
    func setEarlyReminder(id: String, spec: EarlyReminderWrite) async throws -> PrivateResult { calls.append(.setEarlyReminder(id: id, spec: spec)); return try resultOr("updated") }
    func addLocationAlarm(id: String, location: PrivateLocation) async throws -> PrivateResult { calls.append(.addLocationAlarm(id: id, location: location)); return try resultOr("updated") }
    func categorizeGroceryItems(listId: String, reminderIds: [String]) async throws -> PrivateResult { calls.append(.categorizeGroceryItems(listId: listId, reminderIds: reminderIds)); if let e = throwError { throw e }; return groceryResult ?? result }
    func cloneReminderTree(id: String, listId: String, childIds: [String]) async throws -> PrivateResult { calls.append(.cloneReminderTree(id: id, listId: listId, childIds: childIds)); if let e = throwError { throw e }; return cloneResult ?? result }
    func setListAppearance(listId: String, appearance: ListAppearance) async throws -> PrivateResult { try record(.setListAppearance(listId: listId, appearance: appearance)) }
    func setListPinned(listId: String, pinned: Bool) async throws -> PrivateResult { calls.append(.setListPinned(listId: listId, pinned: pinned)); return try resultOr("updated") }
    func setSmartListPinned(smartListId: String, pinned: Bool, isCustom: Bool) async throws -> PrivateResult { calls.append(.setSmartListPinned(smartListId: smartListId, pinned: pinned, isCustom: isCustom)); return try resultOr("updated") }
    func createList(name: String, appearance: ListAppearance) async throws -> PrivateResult { try record(.createList(name: name, appearance: appearance)) }
    func createSmartList(name: String, filterData: Data, appearance: ListAppearance) async throws -> PrivateResult { calls.append(.createSmartList(name: name, filterData: filterData, appearance: appearance)); return try resultOr("created") }
    func updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance) async throws -> PrivateResult { calls.append(.updateSmartList(smartListId: smartListId, filterData: filterData, appearance: appearance)); return try resultOr("updated") }
    func deleteSmartList(smartListId: String) async throws -> PrivateResult { calls.append(.deleteSmartList(smartListId: smartListId)); return try resultOr("deleted") }
    func createTemplate(name: String, sourceListId: String, includeCompleted: Bool) async throws -> PrivateResult { calls.append(.createTemplate(name: name, sourceListId: sourceListId, includeCompleted: includeCompleted)); return try resultOr("created") }
    func applyTemplate(templateId: String) async throws -> PrivateResult { calls.append(.applyTemplate(templateId: templateId)); return try resultOr("updated") }
    func deleteTemplate(templateId: String) async throws -> PrivateResult { calls.append(.deleteTemplate(templateId: templateId)); return try resultOr("deleted") }
    func createSection(listId: String, name: String, existingSectionIds: [String]) async throws -> PrivateResult { try record(.createSection(listId: listId, name: name, existingSectionIds: existingSectionIds)) }
    func renameSection(sectionId: String, name: String) async throws -> PrivateResult { try record(.renameSection(sectionId: sectionId, name: name)) }
    func deleteSection(sectionId: String) async throws -> PrivateResult { try record(.deleteSection(sectionId: sectionId)) }
    func createGroup(name: String) async throws -> PrivateResult { try record(.createGroup(name: name)) }
    func setListParentGroup(listId: String, groupId: String?) async throws -> PrivateResult { try record(.setListParentGroup(listId: listId, groupId: groupId)) }
    func deleteGroup(groupId: String) async throws -> PrivateResult { try record(.deleteGroup(groupId: groupId)) }
    func moveReminderInList(id: String, listId: String, position: String, anchorId: String?) async throws -> PrivateResult { try record(.moveReminderInList(id: id, listId: listId, position: position, anchorId: anchorId)) }
    func setSmartListManualOrder(id: String, smartListId: String, manualOrderingId: String, topLevelElementIds: [String]) async throws -> PrivateResult { try record(.setSmartListManualOrder(id: id, smartListId: smartListId, manualOrderingId: manualOrderingId, topLevelElementIds: topLevelElementIds)) }
    func moveReminderInHierarchy(id: String, listId: String, parentId: String?, position: String, anchorId: String?) async throws -> PrivateResult { try record(.moveReminderInHierarchy(id: id, listId: listId, parentId: parentId, position: position, anchorId: anchorId)) }

    private func record(_ call: Call) throws -> PrivateResult {
        calls.append(call)
        if let e = throwError { throw e }
        onCall?(call)
        return reply?(call) ?? result
    }
}
