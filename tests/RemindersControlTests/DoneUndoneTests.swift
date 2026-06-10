import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct DoneUndoneTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }
    private func withReminder() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Pay rent',10,1,0,'ABC')")
        }
    }
    @Test func doneHuman() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Done.perform(id: 42, json: false, store: s, writer: m)
        #expect(m.calls == [.complete(id: "ABC", completionDate: nil)])
        #expect(out == WriteOutcome.ok("Completed: Pay rent\n"))
    }
    @Test func doneJSONCompact() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Done.perform(id: 42, json: true, store: s, writer: m)
        #expect(out.stdout == #"{"status": "completed", "id": 42, "title": "Pay rent"}"# + "\n")
        #expect(out.exitCode == 0)
        #expect(m.calls == [.complete(id: "ABC", completionDate: nil)])
    }

    // ── done --date (port upstream aba7cf5) ───────────────────────────────────

    private func dateAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func doneWithDateJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Done.perform(id: 42, date: "2026-05-27 09:30", json: true, store: s, writer: m)
        #expect(m.calls == [.complete(id: "ABC", completionDate: dateAt(2026, 5, 27, 9, 30))])
        #expect(out.stdout == #"{"status": "completed", "id": 42, "title": "Pay rent", "completionDate": "2026-05-27T09:30:00"}"# + "\n")
        #expect(out.exitCode == 0)
    }

    @Test func doneWithDateHuman() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Done.perform(id: 42, date: "2026-05-27", json: false, store: s, writer: m)
        #expect(out == WriteOutcome.ok("Completed: Pay rent (2026-05-27T00:00:00)\n"))
        #expect(m.calls == [.complete(id: "ABC", completionDate: dateAt(2026, 5, 27))])
    }

    @Test func doneBadDateExitsTwo() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Done.perform(id: 42, date: "tomorrow", json: false, store: s, writer: m) }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse completion date"))
        #expect(out.stderr.contains("No reminder was changed."))
        #expect(out.stderr.contains("2026-05-27 09:30"))
        #expect(m.calls.isEmpty)
    }

    @Test func doneBadDateExitsTwoJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Done.perform(id: 42, date: "tomorrow", json: true, store: s, writer: m) }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains(#""code": "invalid_completion_date""#))
        #expect(out.stderr.contains(#""field": "date""#))
        #expect(m.calls.isEmpty)
    }

    @Test func doneDateOnRecurringFails() async throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Gym',10,1,0,'ABC')")
            // Weekly recurrence object attached to the reminder (Z_ENT=34, FK ZREMINDER4).
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER4,ZFREQUENCY,ZINTERVAL) VALUES (1,34,0,42,2,1)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Done.perform(id: 42, date: "2026-05-27", json: false, store: s, writer: m) }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("--date is not supported for recurring reminders"))
        #expect(out.stderr.contains("remctl done 42"))
        #expect(m.calls.isEmpty)
    }

    @Test func doneWithoutDateOnRecurringStillCompletes() async throws {
        // No --date on a recurring reminder: normal completion, no guard.
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Gym',10,1,0,'ABC')")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZREMINDER4,ZFREQUENCY,ZINTERVAL) VALUES (1,34,0,42,2,1)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Done.perform(id: 42, json: false, store: s, writer: m)
        #expect(out.exitCode == 0)
        #expect(m.calls == [.complete(id: "ABC", completionDate: nil)])
    }

    @Test func doneNotFound() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Done.perform(id: 99, json: false, store: s, writer: m) }
        #expect(out.stderr == "Error: #99 not found\n"); #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)   // never reached the writer
    }
    @Test func doneNoIdentifierRefuses() async throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (7,'Loose',1,0)")
        }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Done.perform(id: 7, json: false, store: s, writer: m) }
        #expect(out.stderr.contains("no stable identifier")); #expect(out.stderr.contains("complete it")); #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }
    @Test func undoneNotFound() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Undone.perform(id: 99, json: false, store: s, writer: m) }
        #expect(out.stderr == "Error: #99 not found\n"); #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }
    @Test func undoneHumanAndJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let h = try await Undone.perform(id: 42, json: false, store: s, writer: m)
        #expect(m.calls == [.uncomplete(id: "ABC")])
        #expect(h == WriteOutcome.ok("Uncompleted: Pay rent\n"))
        let j = try await Undone.perform(id: 42, json: true, store: s, writer: MockWriter())
        #expect(j.stdout == #"{"status": "uncompleted", "id": 42, "title": "Pay rent"}"# + "\n")
    }
}
