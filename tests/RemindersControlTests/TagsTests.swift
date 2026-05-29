import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct TagsCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["tags"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No tags found\n")
    }

    @Test func emptyJSONIsBracket() throws {
        // JSON branch runs before the empty check -> "[]", NOT "No tags found".
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["tags", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "[]\n")
    }

    @Test func populatedHumanOrderedAndPluralized() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDHASHTAGLABEL (Z_PK,ZNAME) VALUES (1,'work'),(2,'home')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["tags"], storeDir: dir)
        #expect(r.exit == 0)
        // ORDER BY ZNAME -> home then work; magenta suppressed under NO_COLOR
        #expect(r.stdout == "Tags:\n  #home\n  #work\n\n2 tags\n")
    }

    @Test func populatedJSONOrderedByName() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDHASHTAGLABEL (Z_PK,ZNAME) VALUES (1,'work'),(2,'home')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["tags", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?[0]["name"] as? String == "home")
        #expect(parsed?[1]["name"] as? String == "work")
    }

    @Test func singleTagFooterSingular() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDHASHTAGLABEL (Z_PK,ZNAME) VALUES (1,'solo')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["tags"], storeDir: dir)
        #expect(r.stdout.contains("\n1 tag\n"))
    }
}
