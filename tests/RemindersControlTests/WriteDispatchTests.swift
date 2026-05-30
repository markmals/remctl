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
    @Test func noIdentifierEmptyTitleShowsUntitled() throws {
        // An empty-string ZTITLE must be treated as absent → message shows (untitled).
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (8,'',1,0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try WriteDispatch.resolveReminderForWrite(s, id: 8, op: "edit it"); Issue.record("should throw") }
        catch let e as WriteError {
            #expect(e.message.contains("no stable identifier"))
            #expect(e.message.contains("#8 ('(untitled)')"))
        }
    }
    @Test func noIdentifierControlCharTitleScrubbed() throws {
        // A title containing a control character must have it scrubbed by safeDisplay in the message.
        let (s, dir) = try store { db in
            // Title contains a BEL control char (\u{07}) between "Bad" and "Title".
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (9,'Bad\u{07}Title',1,0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try WriteDispatch.resolveReminderForWrite(s, id: 9, op: "complete it"); Issue.record("should throw") }
        catch let e as WriteError {
            #expect(e.message.contains("no stable identifier"))
            // safeDisplay replaces \u{07} (BEL, 0x07 < 0x20) with a space.
            #expect(e.message.contains("#9 ('Bad Title')"))
            // The raw control character must NOT appear in the message.
            #expect(!e.message.contains("\u{07}"))
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
