import Testing
import Foundation
@testable import RemindersControl

// .serialized: these tests mutate the global WriterFactory.make; serialize to avoid
// racing with other factory-mutating suites (e.g. DualDispatchTests).
@Suite(.serialized) struct WriteBoundaryTests {
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
    @Test func dueClearIsModeledOnReminderWrite() async throws {
        let m = MockWriter()
        var w = ReminderWrite(); w.due = .clear
        _ = try await m.update(id: "X", w)
        #expect(m.calls == [.update(id: "X", w)])
        if case .clear = w.due {} else { Issue.record("due should be .clear") }
    }
    @Test func factoryDefaultsToEventKitWriter() {
        #expect(WriterFactory.make() is EventKitWriter)
    }
    @Test func factoryIsOverridable() {
        let saved = WriterFactory.make
        defer { WriterFactory.make = saved }
        let mock = MockWriter()
        WriterFactory.make = { mock }
        #expect(WriterFactory.make() is MockWriter)
    }
}
