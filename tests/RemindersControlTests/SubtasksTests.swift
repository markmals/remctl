import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct SubtasksCommandTests {
    private func storeWithParentAndChild(_ extra: String = "") throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Projects',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
            VALUES (1,'Build deck',10,1,0,0,'PARENT');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER,ZCKIDENTIFIER)
            VALUES (2,'Draft outline',10,1,0,0,1,'CHILD');
            \(extra)
            """)
        }
    }

    @Test func notFoundErrorsAndExits1() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["subtasks", "999"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("Error: #999 not found"))
    }

    @Test func parentWithNoSubtasks() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Lonely',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["subtasks", "1"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "Parent: Lonely\n  No subtasks\n")
    }

    @Test func parentWithChildHuman() throws {
        let dir = try storeWithParentAndChild()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["subtasks", "1"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Parent: Build deck"))
        #expect(r.stdout.contains("Draft outline"))
        #expect(r.stdout.contains("\n1 subtask\n"))
    }

    @Test func jsonHasSubtasksArrayWithParentID() throws {
        let dir = try storeWithParentAndChild()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["subtasks", "1", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(obj?["id"] as? Int == 1)
        let subs = obj?["subtasks"] as? [[String: Any]]
        #expect(subs?.count == 1)
        #expect(subs?.first?["title"] as? String == "Draft outline")
        #expect(subs?.first?["parentID"] as? Int == 1)
        #expect(subs?.first?["isSubtask"] as? Bool == true)
    }

    @Test func completedChildrenIncludedButParentCountActiveOnly() throws {
        // child 2 active, child 3 completed -> subtasks array has 2, parent subtaskCount = 1
        let dir = try storeWithParentAndChild("""
        INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER)
        VALUES (3,'Done child',10,1,1,0,1);
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["subtasks", "1", "--json"], storeDir: dir)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect((obj?["subtasks"] as? [Any])?.count == 2)   // includes completed child
        #expect(obj?["subtaskCount"] as? Int == 1)          // active children only
    }
}
