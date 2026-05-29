import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct FlaggedCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["flagged"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No flagged reminders\n")
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["flagged", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedShowsFlaggedHeader() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZFLAGGED)
            VALUES (1,'Urgent item',10,1,0,0,1);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZFLAGGED)
            VALUES (2,'Not flagged',10,1,0,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["flagged"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Flagged:"))
        #expect(r.stdout.contains("Urgent item"))
        #expect(!r.stdout.contains("Not flagged"))
        #expect(r.stdout.contains("1 flagged"))
    }

    @Test func jsonPopulatedHasFlaggedTrue() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZFLAGGED)
            VALUES (3,'Flagged one',10,1,0,0,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["flagged", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 1)
        #expect(parsed?.first?["flagged"] as? Bool == true)
        #expect(parsed?.first?["id"] as? Int == 3)
    }
}

@Suite struct UrgentCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["urgent"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No urgent reminders\n")
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["urgent", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedShowsUrgentHeader() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZISURGENTSTATEENABLEDFORCURRENTUSER)
            VALUES (1,'Critical',10,1,0,0,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["urgent"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Urgent:"))
        #expect(r.stdout.contains("Critical"))
        #expect(r.stdout.contains("1 urgent"))
    }

    @Test func jsonPopulatedHasUrgentTrue() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZISURGENTSTATEENABLEDFORCURRENTUSER)
            VALUES (7,'Now',10,1,0,0,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["urgent", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 1)
        #expect(parsed?.first?["urgent"] as? Bool == true)
    }
}
