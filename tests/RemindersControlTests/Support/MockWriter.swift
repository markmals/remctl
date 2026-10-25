import Foundation
@testable import RemindersControl

final class MockWriter: RemindersWriter, @unchecked Sendable {
    enum Call: Equatable {
        case authorize
        case create(ReminderWrite)
        case update(id: String, ReminderWrite)
        case delete(id: String)
        case complete(id: String, completionDate: Date?)
        case uncomplete(id: String)
        case createList(title: String, color: String?)
        case renameList(currentTitle: String, listId: String?, newTitle: String)
        case deleteList(title: String, listId: String?)
    }
    private(set) var calls: [Call] = []
    var resultID: String? = "EK-NEW"
    var resultTitle: String? = ""
    var throwError: WriteError?
    /// 1-based indexes of `update` calls that throw, so a test can fail the real write while the
    /// preceding nudge succeeds.
    var failingUpdateCalls: Set<Int> = []
    private var updateCount = 0
    /// Error for `update` only, so a test can fail the EventKit move and still observe the
    /// `delete` that the clone-delete fallback issues.
    var updateError: WriteError?

    private func resultOr(_ status: String) throws -> WriteResult {
        if let e = throwError { throw e }
        return WriteResult(status: status, id: resultID, title: resultTitle)
    }
    func authorize() async throws -> AuthSummary { calls.append(.authorize); return AuthSummary(calendarCount: 1, defaultList: "Reminders") }
    func create(_ w: ReminderWrite) async throws -> WriteResult { calls.append(.create(w)); return try resultOr("created") }
    func update(id: String, _ w: ReminderWrite) async throws -> WriteResult {
        calls.append(.update(id: id, w))
        updateCount += 1
        if failingUpdateCalls.contains(updateCount) { throw WriteError("update failed") }
        if let e = updateError { throw e }
        return try resultOr("updated")
    }
    func delete(id: String) async throws -> WriteResult { calls.append(.delete(id: id)); return try resultOr("deleted") }
    func complete(id: String, completionDate: Date?) async throws -> WriteResult { calls.append(.complete(id: id, completionDate: completionDate)); return try resultOr("completed") }
    func uncomplete(id: String) async throws -> WriteResult { calls.append(.uncomplete(id: id)); return try resultOr("uncompleted") }
    func createList(title: String, color: String?) async throws -> WriteResult { calls.append(.createList(title: title, color: color)); return try resultOr("created") }
    func renameList(currentTitle: String, listId: String?, newTitle: String) async throws -> WriteResult { calls.append(.renameList(currentTitle: currentTitle, listId: listId, newTitle: newTitle)); return try resultOr("renamed") }
    func deleteList(title: String, listId: String?) async throws -> WriteResult { calls.append(.deleteList(title: title, listId: listId)); return try resultOr("deleted") }
}
