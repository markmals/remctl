import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct SearchCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "milk"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No reminders matching 'milk'\n")
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "nothing", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedShowsSearchHeader() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Buy milk',10,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (2,'Buy eggs',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "milk"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Search: milk"))
        #expect(r.stdout.contains("Buy milk"))
        #expect(!r.stdout.contains("Buy eggs"))
        #expect(r.stdout.contains("1 result"))
    }

    @Test func pluralResultsWording() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Buy item a',10,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (2,'Buy item b',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "Buy"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("2 results"))
    }

    @Test func completedFlagIncludesCompletedItems() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Done task',10,1,1,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // Without --completed: not found
        let r1 = try CLIRunner.run(["search", "Done"], storeDir: dir)
        #expect(r1.stdout.contains("No reminders matching"))
        // With --completed: found
        let r2 = try CLIRunner.run(["search", "Done", "--completed"], storeDir: dir)
        #expect(r2.stdout.contains("Done task"))
    }

    @Test func jsonPopulatedHasTitle() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (42,'Find me',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "Find", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 1)
        #expect(parsed?.first?["title"] as? String == "Find me")
        #expect(parsed?.first?["id"] as? Int == 42)
    }
}
