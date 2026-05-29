import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct ShowCommandTests {
    @Test func neitherArgError() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("pass a list name or --list-id"))
    }

    @Test func notFoundError() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Nope"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("Error: list not found: Nope"))
    }

    @Test func emptyActiveMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Work"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No active reminders in 'Work'\n")
    }

    @Test func basicNoSections() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (10,'Ship it',1,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Work"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Work:"))
        #expect(r.stdout.contains("Ship it"))
        #expect(r.stdout.contains("\n1 reminder\n"))
    }

    /// Grocery list with two sections + membership blob mapping reminders to sections.
    private func groceryFixture(_ displayDairy: String) throws -> URL {
        let blob = #"{"memberships":[{"memberID":"REM-1","groupID":"SEC-1"},{"memberID":"REM-2","groupID":"SEC-2"}]}"#
        return try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql:
                "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS,ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA) VALUES (1,3,'Groceries',0,1,?)",
                arguments: [blob])
            try db.execute(sql: """
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (100,?,1,'SEC-1',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (101,'Household Items',1,'SEC-2',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,'Milk',1,1,0,0,'REM-1');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (11,'Trash bags',1,1,0,0,'REM-2');
            """, arguments: [displayDairy])
        }
    }

    @Test func groceryHumanSectionsWithEmoji() throws {
        let dir = try groceryFixture("Dairy, Eggs &amp; Cheese")  // escaped in DB
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Groceries"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Groceries 🥕:"))   // grocery marker on heading
        #expect(r.stdout.contains("[🥛 Dairy, Eggs & Cheese]"))   // unescaped + emoji
        #expect(r.stdout.contains("[🧻 Household Items]"))
    }

    @Test func groceryJSONSectionAndEmoji() throws {
        let dir = try groceryFixture("Dairy, Eggs & Cheese")  // already unescaped (matches oracle JSON test)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Groceries", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let milk = arr?.first { $0["title"] as? String == "Milk" }
        #expect(milk?["section"] as? String == "Dairy, Eggs & Cheese")
        #expect(milk?["sectionEmoji"] as? String == "🥛")
    }
}
