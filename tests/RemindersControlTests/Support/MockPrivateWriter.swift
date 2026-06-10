import Foundation
@testable import RemindersControl

final class MockPrivateWriter: PrivateWriter, @unchecked Sendable {
    enum Call: Equatable {
        case setFlagged(id: String, flagged: Bool)
        case addPrivateMetadata(id: String, urls: [String], tags: [String])
        case assignSection(id: String, sectionId: String)
        case assignSharee(id: String, assigneeId: String, originatorId: String)
        case clearAssignment(id: String)
        case addSectionAndAssign(id: String, name: String)
        case addSubtasks(id: String, subtasks: [SubtaskSpec])
        case addAttachments(id: String, images: [String])
        case setUrgent(id: String, urgent: Bool)
        case setEarlyReminder(id: String, spec: EarlyReminderWrite)
        case addLocationAlarm(id: String, location: PrivateLocation)
        case categorizeGroceryItems(listId: String, reminderIds: [String])
        case setListAppearance(listId: String, appearance: ListAppearance)
        case setListPinned(listId: String, pinned: Bool)
        case setSmartListPinned(smartListId: String, pinned: Bool)
        case createList(name: String, appearance: ListAppearance)
        case createSmartList(name: String, filterData: Data, appearance: ListAppearance)
        case updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance)
        case deleteSmartList(smartListId: String)
        case createTemplate(name: String, sourceListId: String, includeCompleted: Bool)
        case applyTemplate(templateId: String)
        case deleteTemplate(templateId: String)
    }
    private(set) var calls: [Call] = []
    var result = PrivateResult(status: "updated")
    /// Per-method result override for `addSubtasks` so tests can return child {id,title,url} entries
    /// (P13 pairs each created child to its spec via `fields["subtasks"]`).
    var subtasksResult: PrivateResult?
    /// Per-method result override for `categorizeGroceryItems` (P14) so tests can simulate the
    /// helper returning an error/non-updated status independently of the shared `result`.
    var groceryResult: PrivateResult?
    var throwError: Error?

    private func resultOr(_ status: String) throws -> PrivateResult {
        if let e = throwError { throw e }
        return result
    }

    func setFlagged(id: String, flagged: Bool) async throws -> PrivateResult { calls.append(.setFlagged(id: id, flagged: flagged)); return try resultOr("updated") }
    func addPrivateMetadata(id: String, urls: [String], tags: [String]) async throws -> PrivateResult { calls.append(.addPrivateMetadata(id: id, urls: urls, tags: tags)); return try resultOr("updated") }
    func assignSection(id: String, sectionId: String) async throws -> PrivateResult { calls.append(.assignSection(id: id, sectionId: sectionId)); return try resultOr("updated") }
    func assignSharee(id: String, assigneeId: String, originatorId: String) async throws -> PrivateResult { calls.append(.assignSharee(id: id, assigneeId: assigneeId, originatorId: originatorId)); return try resultOr("updated") }
    func clearAssignment(id: String) async throws -> PrivateResult { calls.append(.clearAssignment(id: id)); return try resultOr("updated") }
    func addSectionAndAssign(id: String, name: String) async throws -> PrivateResult { calls.append(.addSectionAndAssign(id: id, name: name)); return try resultOr("updated") }
    func addSubtasks(id: String, subtasks: [SubtaskSpec]) async throws -> PrivateResult { calls.append(.addSubtasks(id: id, subtasks: subtasks)); if let e = throwError { throw e }; return subtasksResult ?? result }
    func addAttachments(id: String, images: [String]) async throws -> PrivateResult { calls.append(.addAttachments(id: id, images: images)); return try resultOr("updated") }
    func setUrgent(id: String, urgent: Bool) async throws -> PrivateResult { calls.append(.setUrgent(id: id, urgent: urgent)); return try resultOr("updated") }
    func setEarlyReminder(id: String, spec: EarlyReminderWrite) async throws -> PrivateResult { calls.append(.setEarlyReminder(id: id, spec: spec)); return try resultOr("updated") }
    func addLocationAlarm(id: String, location: PrivateLocation) async throws -> PrivateResult { calls.append(.addLocationAlarm(id: id, location: location)); return try resultOr("updated") }
    func categorizeGroceryItems(listId: String, reminderIds: [String]) async throws -> PrivateResult { calls.append(.categorizeGroceryItems(listId: listId, reminderIds: reminderIds)); if let e = throwError { throw e }; return groceryResult ?? result }
    func setListAppearance(listId: String, appearance: ListAppearance) async throws -> PrivateResult { calls.append(.setListAppearance(listId: listId, appearance: appearance)); return try resultOr("updated") }
    func setListPinned(listId: String, pinned: Bool) async throws -> PrivateResult { calls.append(.setListPinned(listId: listId, pinned: pinned)); return try resultOr("updated") }
    func setSmartListPinned(smartListId: String, pinned: Bool) async throws -> PrivateResult { calls.append(.setSmartListPinned(smartListId: smartListId, pinned: pinned)); return try resultOr("updated") }
    func createList(name: String, appearance: ListAppearance) async throws -> PrivateResult { calls.append(.createList(name: name, appearance: appearance)); return try resultOr("created") }
    func createSmartList(name: String, filterData: Data, appearance: ListAppearance) async throws -> PrivateResult { calls.append(.createSmartList(name: name, filterData: filterData, appearance: appearance)); return try resultOr("created") }
    func updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance) async throws -> PrivateResult { calls.append(.updateSmartList(smartListId: smartListId, filterData: filterData, appearance: appearance)); return try resultOr("updated") }
    func deleteSmartList(smartListId: String) async throws -> PrivateResult { calls.append(.deleteSmartList(smartListId: smartListId)); return try resultOr("deleted") }
    func createTemplate(name: String, sourceListId: String, includeCompleted: Bool) async throws -> PrivateResult { calls.append(.createTemplate(name: name, sourceListId: sourceListId, includeCompleted: includeCompleted)); return try resultOr("created") }
    func applyTemplate(templateId: String) async throws -> PrivateResult { calls.append(.applyTemplate(templateId: templateId)); return try resultOr("updated") }
    func deleteTemplate(templateId: String) async throws -> PrivateResult { calls.append(.deleteTemplate(templateId: templateId)); return try resultOr("deleted") }
}
