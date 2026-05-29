import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct CSVWriterTests {
    @Test func minimalQuotingAndCRLF() {
        let out = CSV.writeRows([["a", "b,c", "d\"e"], ["1", "2", "3"]])
        #expect(out == "a,\"b,c\",\"d\"\"e\"\r\n1,2,3\r\n")
    }
    @Test func plainFieldsUnquoted() {
        #expect(CSV.field("plain") == "plain")
        #expect(CSV.field("has,comma") == "\"has,comma\"")
        #expect(CSV.field("has\nnewline") == "\"has\nnewline\"")
    }
}

@Suite struct ExportCommandTests {
    /// list 'Work' (id 10): r1 active flagged w/ tag, r2 completed, r3 subtask of r1.
    private func fixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZFLAGGED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
            VALUES (1,'Top',10,1,0,1,0,'A');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (2,'Done',10,1,1,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER)
            VALUES (3,'Child',10,1,0,0,1);
            INSERT INTO ZREMCDHASHTAGLABEL (Z_PK,ZNAME) VALUES (50,'urgent');
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER3,ZHASHTAGLABEL) VALUES (200,1,50);
            """)
        }
    }

    @Test func emptyJSONIsBracket() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "[]\n")
    }

    @Test func emptyCSVIsHeaderOnly() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export", "--format", "csv"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "id,title,list,completed,flagged,urgent,priority,due_date,notes,url,tags\r\n")
    }

    @Test func jsonFlatIncludesCompletedAndSubtasks() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        // flat: all 3 reminders (completed + subtask included)
        #expect(arr?.count == 3)
        let ids = Set(arr?.compactMap { $0["id"] as? Int } ?? [])
        #expect(ids == [1, 2, 3])
    }

    @Test func csvRowsBooleansAndTags() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export", "--format", "csv"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.hasPrefix("id,title,list,completed,flagged,urgent,priority,due_date,notes,url,tags\r\n"))
        // r1: active(False completed), flagged True, tag 'urgent'
        #expect(r.stdout.contains("1,Top,Work,False,True,False,none,,,,urgent\r\n"))
        // r2: completed True
        #expect(r.stdout.contains("2,Done,Work,True,False,False,none,,,,\r\n"))
    }

    @Test func listIdFilters() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export", "--list-id", "10"], storeDir: dir)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(arr?.count == 3)
    }

    @Test func listByNameResolves() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export", "--list", "work"], storeDir: dir)  // case-insensitive
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(arr?.count == 3)
    }

    @Test func listNotFoundErrors() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export", "--list", "Nonexistent"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("Error: list not found: Nonexistent"))
    }

    @Test func bothListAndIdErrors() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["export", "--list", "Work", "--list-id", "10"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("pass either a list name or --list-id, not both"))
    }
}
