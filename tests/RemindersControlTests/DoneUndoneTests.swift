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
        #expect(m.calls == [.complete(id: "ABC")])
        #expect(out == WriteOutcome.ok("Completed: Pay rent\n"))
    }
    @Test func doneJSONCompact() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Done.perform(id: 42, json: true, store: s, writer: m)
        #expect(out.stdout == #"{"status": "completed", "id": 42, "title": "Pay rent"}"# + "\n")
        #expect(out.exitCode == 0)
        #expect(m.calls == [.complete(id: "ABC")])
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
