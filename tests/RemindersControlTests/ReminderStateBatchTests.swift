import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `done` / `undone` / `delete` with several ids (port of upstream `run_reminder_state_batch`).
@Suite struct ReminderStateBatchTests {
    /// A Work list holding #1 One, #2 Two, #3 'Weekly review' (recurring), #4 Loose (no identifier).
    private func fixture() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES
              (1,'One',10,1,0,'CK-1'), (2,'Two',10,1,0,'CK-2'), (3,'Weekly review',10,1,0,'CK-3'), (4,'Loose',10,1,0,NULL)
            """)
            // Weekly recurrence object attached to #3 (Z_ENT=34, FK ZREMINDER4).
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER4,ZFREQUENCY,ZINTERVAL) VALUES (1,34,0,3,2,1)")
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Removes a reminder row through a second connection, the way Reminders drops a subtask when
    /// its parent is deleted earlier in the same batch.
    private static func removeRow(_ pk: Int, in dir: URL) throws {
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path)
        try queue.write { try $0.execute(sql: "DELETE FROM ZREMCDREMINDER WHERE Z_PK = ?", arguments: [pk]) }
    }

    private let looseRefusal = "The reminder has no stable identifier. Refusing unsafe title-based fallback "
        + "for #4 ('Loose') while trying to "

    // ── Resolution happens before the first write ─────────────────────────────

    @Test func everyIdIsResolvedBeforeTheFirstWrite() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        // #3 disappears from the store while #1 is being written. It was resolved up front, so it
        // is still written; a lazily resolved batch would report it as not found.
        m.onStateWrite = { id in if id == "CK-1" { try Self.removeRow(3, in: dir) } }

        let out = await ReminderStateBatch.run(operation: .done, ids: [1, 999, 4, 3], json: true,
                                               store: s, writer: m, confirm: .unexpected)

        #expect(m.calls == [.complete(id: "CK-1", completionDate: nil), .complete(id: "CK-3", completionDate: nil)])
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "batch_partial")
        let summary = try #require(payload["summary"] as? [String: Any])
        #expect(summary["status"] as? String == "partial")
        #expect(summary["failed"] as? [Int] == [999, 4])
    }

    @Test func duplicateIdsAreWrittenOnceAndReported() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await ReminderStateBatch.run(operation: .done, ids: [1, 1, 2], json: false,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(m.calls == [.complete(id: "CK-1", completionDate: nil), .complete(id: "CK-2", completionDate: nil)])
        #expect(out.stdout == "Completed: #1 One\nCompleted: #2 Two\nIgnored repeated ids: 1\n2 of 2 completed\n")
        #expect(out.stderr.isEmpty)
        #expect(out.exitCode == 0)

        let js = MockWriter()
        let json = await ReminderStateBatch.run(operation: .done, ids: [1, 1, 2], json: true,
                                                store: s, writer: js, confirm: .unexpected)
        #expect(json.stdout.contains(#""requested": [1, 1, 2]"#))
        #expect(json.stdout.hasSuffix(#""duplicatesIgnored": [1]}"# + "\n"))
    }

    @Test func moreThanFiftyIdsIsRefusedWithoutWriting() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = Array(1...51)
        let m = MockWriter()
        let human = await ReminderStateBatch.run(operation: .done, ids: ids, json: false,
                                                 store: s, writer: m, confirm: .unexpected)
        #expect(human.stderr == "Error: Pass at most 50 reminder ids per call; got 51. Nothing was changed.\n")
        #expect(human.stdout.isEmpty)
        #expect(human.exitCode == 1)

        let json = await ReminderStateBatch.run(operation: .delete, ids: ids, force: true, json: true,
                                                store: s, writer: m, confirm: .unexpected)
        #expect(json.stderr == #"{"status": "error", "code": "batch_too_large", "message": "Pass at most 50 reminder ids per call; got 51. Nothing was changed."}"# + "\n")
        #expect(json.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    // ── done --date ───────────────────────────────────────────────────────────

    @Test func dateOnARecurringIdFailsOnlyThatId() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await ReminderStateBatch.run(operation: .done, ids: [1, 3], date: "2026-09-01", json: true,
                                               store: s, writer: m, confirm: .unexpected)
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        #expect(m.calls == [.complete(id: "CK-1", completionDate: expected)])
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "batch_partial")
        #expect((payload["summary"] as? [String: Any])?["failed"] as? [Int] == [3])
    }

    @Test func anUnparseableDateStopsTheBatchBeforeAnyWrite() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await ReminderStateBatch.run(operation: .done, ids: [1, 2], date: "next friday", json: true,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains(#""code": "invalid_completion_date""#))
        #expect(m.calls.isEmpty)
    }

    // ── A failed write does not stop the batch ────────────────────────────────

    @Test func aWriterErrorFailsOneIdAndLaterIdsStillRun() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.onStateWrite = { id in if id == "CK-1" { throw WriteError("EventKit refused") } }
        let out = await ReminderStateBatch.run(operation: .done, ids: [1, 2, 3], json: true,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(m.calls == [.complete(id: "CK-1", completionDate: nil), .complete(id: "CK-2", completionDate: nil),
                            .complete(id: "CK-3", completionDate: nil)])
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "batch_partial")
        let summary = try #require(payload["summary"] as? [String: Any])
        #expect(summary["failed"] as? [Int] == [1])
    }

    @Test func everyIdFailingReportsFailedAndExitsOne() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.onStateWrite = { _ in throw WriteError("EventKit refused") }
        let out = await ReminderStateBatch.run(operation: .undone, ids: [1, 2], json: true,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(out.stdout.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "batch_failed")
        #expect(out.exitCode == 1)
    }

    // ── delete ────────────────────────────────────────────────────────────────

    @Test func deleteAsksOnceForTheWholeBatchAndWritesNothingWhenDeclined() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let seen = Prompted()
        let out = await ReminderStateBatch.run(operation: .delete, ids: [1, 2, 4], json: false, store: s,
                                               writer: m, confirm: .recording({ seen.value = $0 }, answer: "n"))
        #expect(seen.value == "Delete 2 reminders?\n  #1 'One' (Work)\n  #2 'Two' (Work)\n[y/N] ")
        #expect(out == WriteOutcome.ok("Cancelled.\n"))   // exit 0, like the single delete
        #expect(m.calls.isEmpty)
    }

    @Test func deleteWithOneTargetUsesTheSingularPrompt() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let seen = Prompted()
        let out = await ReminderStateBatch.run(operation: .delete, ids: [1, 999], json: false, store: s,
                                               writer: m, confirm: .recording({ seen.value = $0 }))
        #expect(seen.value == "Delete 1 reminder?\n  #1 'One' (Work)\n[y/N] ")
        #expect(m.calls == [.delete(id: "CK-1")])
        #expect(out.stdout == "Deleted: #1 One\n1 of 2 deleted\n")
        #expect(out.stderr == "Error: #999 not found\n")
        #expect(out.exitCode == 1)
    }

    @Test func deleteWithoutForceRefusesUnderJSONAndNamesEveryTarget() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await ReminderStateBatch.run(operation: .delete, ids: [1, 2], json: true,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == #"{"status": "error", "code": "confirmation_required", "message": "Refusing to continue without --force when --json is used or stdin is not interactive.", "ids": [1, 2]}"# + "\n")
        #expect(m.calls.isEmpty)
    }

    @Test func deleteNeverPromptsWhenNoIdResolves() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        // `.unexpected` records an issue if the prompt is shown.
        let out = await ReminderStateBatch.run(operation: .delete, ids: [999, 4], json: false,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(out.stderr == "Error: #999 not found\nError: \(looseRefusal)delete it.\n")
        #expect(out.stdout == "0 of 2 deleted\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    @Test func aTargetThatVanishedWithItsParentCountsAsDeleted() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.onStateWrite = { id in
            if id == "CK-1" { try Self.removeRow(2, in: dir) }
            if id == "CK-2" { throw WriteError("Reminder not found for id: CK-2") }
        }
        let out = await ReminderStateBatch.run(operation: .delete, ids: [1, 2], force: true, json: true,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(m.calls == [.delete(id: "CK-1"), .delete(id: "CK-2")])
        #expect(out.exitCode == 0)
        #expect(out.stdout == #"{"status": "deleted", "operation": "delete", "requested": [1, 2], "succeeded": [1, 2], "failed": [], "results": [{"id": 1, "status": "deleted", "title": "One", "list": "Work"}, {"id": 2, "status": "deleted", "title": "Two", "list": "Work"}]}"# + "\n")
    }

    // ── undone + the one-id batch shape ───────────────────────────────────────

    @Test func undoneBatchPrintsOneLinePerIdAndACount() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await ReminderStateBatch.run(operation: .undone, ids: [1, 2, 999], json: false,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(m.calls == [.uncomplete(id: "CK-1"), .uncomplete(id: "CK-2")])
        #expect(out.stdout == "Uncompleted: #1 One\nUncompleted: #2 Two\n2 of 3 uncompleted\n")
        #expect(out.stderr == "Error: #999 not found\n")
        #expect(out.exitCode == 1)
    }

    @Test func oneIdGetsTheWholeBatchShape() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await ReminderStateBatch.run(operation: .done, ids: [1], json: true,
                                               store: s, writer: m, confirm: .unexpected)
        #expect(out.exitCode == 0)
        #expect(out.stdout == #"{"status": "completed", "operation": "done", "requested": [1], "succeeded": [1], "failed": [], "results": [{"id": 1, "status": "completed", "title": "One", "list": "Work"}]}"# + "\n")
    }
}

/// The CLI chooses the single-id path or the batch path, through the real binary.
@Suite struct ReminderStateBatchCLITests {
    private func emptyStore() throws -> URL {
        try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
    }

    @Test func oneIdKeepsTheSingleIdOutput() throws {
        let dir = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["done", "7", "--json"], storeDir: dir)
        #expect(r.stderr.contains(#""code": "not_found""#))
        #expect(r.stdout.isEmpty)
        #expect(r.exit == 1)
    }

    @Test func twoIdsUseTheBatchPath() throws {
        let dir = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["done", "7", "8", "--json"], storeDir: dir)
        #expect(r.stdout.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(r.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "batch_failed")
        #expect((payload["summary"] as? [String: Any])?["failed"] as? [Int] == [7, 8])
        #expect(r.exit == 1)
    }

    @Test func batchFlagGivesOneIdTheBatchShape() throws {
        let dir = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["undone", "7", "--batch", "--json"], storeDir: dir)
        #expect(r.stdout.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(r.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "batch_failed")
        #expect(r.exit == 1)
    }

    @Test func helpShowsRepeatableIdsAndTheBatchFlag() throws {
        let r = try CLIRunner.run(["done", "--help"])
        #expect(r.stdout.contains("remctl done <id> [<id> ...]"))
        #expect(r.stdout.contains("--batch"))
        #expect(r.stdout.contains("Several ids make one batch of up to 50"))
    }
}
