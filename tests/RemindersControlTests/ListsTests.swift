import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct ListsCommandTests {
    @Test func emptyJSONIsBracket() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "[]\n")
    }

    @Test func emptyHumanFooter() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists"], storeDir: dir)
        #expect(r.stdout == "Reminder Lists:\n\n0 lists\n")
    }

    @Test func jsonReportsGroceryMetadata() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS,ZSHOULDAUTOCATEGORIZEITEMS,ZGROCERYLOCALEID)
            VALUES (1,3,'Groceries',0,1,0,'en_US');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS)
            VALUES (2,3,'Work',0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        // ORDER BY ZNAME: Groceries before Work
        let groceries = arr?[0]; let work = arr?[1]
        #expect(groceries?["title"] as? String == "Groceries")
        #expect(groceries?["listType"] as? String == "groceries")
        #expect(groceries?["isGroceries"] as? Bool == true)
        let g = groceries?["grocery"] as? [String: Any]
        #expect(g?["locale"] as? String == "en_US")
        #expect(g?["shouldCategorizeItems"] as? Bool == true)
        #expect(g?["shouldAutoCategorizeItems"] as? Bool == false)
        #expect(work?["listType"] as? String == "standard")
        #expect(work?["isGroceries"] as? Bool == false)
        #expect(work?["grocery"] == nil)   // omitted when not groceries and all-false
    }

    @Test func humanMarksGroceriesWithCarrot() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS) VALUES (1,3,'Groceries',0,1)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists"], storeDir: dir)
        #expect(r.stdout.contains("Groceries"))
        #expect(r.stdout.contains("🥕"))
        #expect(r.stdout.contains("(id: 1)"))
        #expect(r.stdout.contains("\n1 list\n"))
    }

    @Test func appearanceBadgeAndColorFallback() throws {
        // ZBADGEEMBLEM JSON with Emoji; ZCOLOR a non-plist blob -> default color.
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZBADGEEMBLEM,ZCOLOR) VALUES (1,3,'Projects',0,?,?)",
                           arguments: [#"{"Emoji" : "📌"}"#, Data("not-a-color".utf8)])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let item = arr?.first
        let badge = item?["badge"] as? [String: Any]
        #expect(badge?["emoji"] as? String == "📌")
        let color = item?["color"] as? [String: Any]
        #expect(color?["hex"] as? String == "#007AFF")   // parse failure -> default blue
        #expect(color?["name"] as? String == "blue")
    }
}
