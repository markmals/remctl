import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct SectionsCommandTests {
    /// Two lists (Home, Work); Home has 1 section, Work has 2. ORDER BY l.ZNAME, s.Z_PK.
    private func fixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0),(2,3,'Home',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZMARKEDFORDELETION) VALUES (10,'Inbox',1,0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZMARKEDFORDELETION) VALUES (11,'Later',1,0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZMARKEDFORDELETION) VALUES (12,'Chores',2,0);
            """)
        }
    }

    @Test func emptyHuman() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sections"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No sections found\n")
    }

    @Test func emptyJSONIsObjectBraces() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sections", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "{}\n")
    }

    @Test func jsonGroupedByListNameOrdered() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sections", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect((d?["Home"] as? [String]) == ["Chores"])
        #expect((d?["Work"] as? [String]) == ["Inbox", "Later"])  // ascending Z_PK within list
        // first-seen key order: Home before Work (ORDER BY l.ZNAME binary)
        let homeIdx = r.stdout.range(of: "\"Home\"")!.lowerBound
        let workIdx = r.stdout.range(of: "\"Work\"")!.lowerBound
        #expect(homeIdx < workIdx)
    }

    @Test func humanGroupedHeadersAndFooter() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sections"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Home:\n  - Chores"))
        #expect(r.stdout.contains("Work:\n  - Inbox\n  - Later"))
        #expect(r.stdout.contains("\n3 sections\n"))
    }
}
