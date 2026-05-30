import Testing
import Foundation
@testable import RemindersControl

@Suite struct WriteBoundaryTests {
    @Test func mockRecordsCreateAndReturnsResult() async throws {
        let m = MockWriter(); m.resultID = "EK-42"; m.resultTitle = "Buy milk"
        var w = ReminderWrite(); w.title = "Buy milk"; w.priority = 1
        let r = try await m.create(w)
        #expect(m.calls == [.create(w)])
        #expect(r == WriteResult(status: "created", id: "EK-42", title: "Buy milk"))
    }
    @Test func mockPropagatesThrow() async {
        let m = MockWriter(); m.throwError = WriteError("Save failed: nope")
        await #expect(throws: WriteError.self) { _ = try await m.complete(id: "X") }
    }
    @Test func writeErrorCarriesExitCode() {
        #expect(WriteError("bad due", exitCode: 2).exitCode == 2)
        #expect(WriteError("generic").exitCode == 1)
    }
    @Test func reminderWriteEquatableOnFields() {
        var a = ReminderWrite(); a.title = "x"; a.due = .clear
        var b = ReminderWrite(); b.title = "x"; b.due = .clear
        #expect(a == b)
        b.due = .set(Date(timeIntervalSince1970: 0))
        #expect(a != b)
    }
}
