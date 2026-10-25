import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct DeleteTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }
    private func withReminder() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Home',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Pay rent',10,1,0,'ABC')")
        }
    }
    @Test func forceDeletes() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Delete.perform(id: 42, force: true, json: false, store: s, writer: m, confirm: .unexpected)
        #expect(m.calls == [.delete(id: "ABC")])
        #expect(out == WriteOutcome.ok("Deleted: Pay rent\n"))
    }
    @Test func confirmYesDeletes() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let seen = Prompted()
        let out = try await Delete.perform(id: 42, force: false, json: false, store: s, writer: m, confirm: .recording { seen.value = $0 })
        #expect(seen.value == "Delete 'Pay rent' from Home? [y/N] ")
        #expect(m.calls == [.delete(id: "ABC")])
        #expect(out.stdout == "Deleted: Pay rent\n")
    }
    @Test func confirmNoCancels() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Delete.perform(id: 42, force: false, json: false, store: s, writer: m, confirm: .answering("n"))
        #expect(out == WriteOutcome.ok("Cancelled.\n"))   // exit 0
        #expect(m.calls.isEmpty)
    }
    @Test func jsonWithoutForceRefuses() async throws {
        // --json must never block on a prompt: it refuses and writes nothing (upstream 374c24d).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Delete.perform(id: 42, force: false, json: true, store: s, writer: m, confirm: .unexpected)
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == #"{"status": "error", "code": "confirmation_required", "message": "Refusing to continue without --force when --json is used or stdin is not interactive.", "id": 42}"# + "\n")
        #expect(m.calls.isEmpty)
    }
    @Test func nonInteractiveStdinWithoutForceRefuses() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Delete.perform(id: 42, force: false, json: false, store: s, writer: m, confirm: .nonInteractive)
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == "Error: Refusing to continue without --force when --json is used or stdin is not interactive.\n")
        #expect(m.calls.isEmpty)
    }
    @Test func endOfInputWithoutAnswerRefuses() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Delete.perform(id: 42, force: false, json: false, store: s, writer: m, confirm: .endOfInput)
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: confirmation input ended before an answer was received.\n")
        #expect(m.calls.isEmpty)
    }
    @Test func jsonCompact() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Delete.perform(id: 42, force: true, json: true, store: s, writer: m, confirm: .unexpected)
        #expect(out.stdout == #"{"status": "deleted", "id": 42, "title": "Pay rent"}"# + "\n")
        #expect(m.calls == [.delete(id: "ABC")])
    }
    @Test func notFound() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Delete.perform(id: 99, force: true, json: false, store: s, writer: m, confirm: .unexpected) }
        #expect(out.stderr == "Error: #99 not found\n"); #expect(out.exitCode == 1); #expect(m.calls.isEmpty)
    }
    @Test func noIdentifierRefuses() async throws {
        let (s, dir) = try store { db in try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (7,'Loose',1,0)") }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await Delete.perform(id: 7, force: true, json: false, store: s, writer: m, confirm: .unexpected) }
        #expect(out.stderr.contains("no stable identifier")); #expect(out.stderr.contains("delete it")); #expect(out.exitCode == 1); #expect(m.calls.isEmpty)
    }
}
