import Foundation
@testable import RemindersControl

final class MockWriter: RemindersWriter, @unchecked Sendable {
    enum Call: Equatable {
        case authorize
        case create(ReminderWrite)
        case update(id: String, ReminderWrite, clearDue: Bool)
        case delete(id: String)
        case complete(id: String)
        case uncomplete(id: String)
        case createList(title: String, color: String?)
        case renameList(currentTitle: String, newTitle: String)
        case deleteList(title: String)
    }
    private(set) var calls: [Call] = []
    var resultID: String? = "EK-NEW"
    var resultTitle: String? = ""
    var throwError: WriteError?

    private func resultOr(_ status: String) throws -> WriteResult {
        if let e = throwError { throw e }
        return WriteResult(status: status, id: resultID, title: resultTitle)
    }
    func authorize() async throws -> AuthSummary { calls.append(.authorize); return AuthSummary(calendarCount: 1, defaultList: "Reminders") }
    func create(_ w: ReminderWrite) async throws -> WriteResult { calls.append(.create(w)); return try resultOr("created") }
    func update(id: String, _ w: ReminderWrite, clearDue: Bool) async throws -> WriteResult { calls.append(.update(id: id, w, clearDue: clearDue)); return try resultOr("updated") }
    func delete(id: String) async throws -> WriteResult { calls.append(.delete(id: id)); return try resultOr("deleted") }
    func complete(id: String) async throws -> WriteResult { calls.append(.complete(id: id)); return try resultOr("completed") }
    func uncomplete(id: String) async throws -> WriteResult { calls.append(.uncomplete(id: id)); return try resultOr("uncompleted") }
    func createList(title: String, color: String?) async throws -> WriteResult { calls.append(.createList(title: title, color: color)); return try resultOr("created") }
    func renameList(currentTitle: String, newTitle: String) async throws -> WriteResult { calls.append(.renameList(currentTitle: currentTitle, newTitle: newTitle)); return try resultOr("renamed") }
    func deleteList(title: String) async throws -> WriteResult { calls.append(.deleteList(title: title)); return try resultOr("deleted") }
}
