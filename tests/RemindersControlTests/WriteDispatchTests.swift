import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct WriteDispatchTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }
    @Test func resolvesPresentReminder() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Pay rent',10,1,0,'ABC')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try WriteDispatch.resolveReminderForWrite(s, id: 42, op: "complete it")
        #expect(r.title == "Pay rent"); #expect(r.ckid == "ABC")
    }
    @Test func notFoundThrows() throws {
        let (s, dir) = try store { _ in }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: WriteError.self) { _ = try WriteDispatch.resolveReminderForWrite(s, id: 99, op: "complete it") }
    }
    @Test func noIdentifierRefuses() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (7,'Loose',1,0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try WriteDispatch.resolveReminderForWrite(s, id: 7, op: "delete it"); Issue.record("should throw") }
        catch let e as WriteError {
            #expect(e.message.contains("no stable identifier"))
            #expect(e.message.contains("#7 ('Loose')"))
            #expect(e.message.contains("delete it"))
        }
    }
    @Test func performMapsWriteErrorExitCode() async {
        let out = await WriteDispatch.perform { throw WriteError("bad due", exitCode: 2) }
        #expect(out == WriteOutcome.error("bad due", code: 2))
        #expect(out.exitCode == 2)
        #expect(out.stderr == "Error: bad due\n")
    }
    @Test func performReturnsSuccess() async {
        let out = await WriteDispatch.perform { .ok("Done\n") }
        #expect(out == WriteOutcome.ok("Done\n"))
    }
}
