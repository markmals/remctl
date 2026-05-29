import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct StatsCommandTests {
    /// 1 list, 1 section; reminder 1 active+flagged, reminder 2 completed.
    private func fixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZMARKEDFORDELETION) VALUES (20,'Inbox',10,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZFLAGGED,ZMARKEDFORDELETION)
            VALUES (1,'active flagged',10,1,0,1,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZFLAGGED,ZMARKEDFORDELETION)
            VALUES (2,'done',10,1,1,0,0);
            """)
        }
    }

    @Test func jsonValuesAndKeyOrder() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["stats", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["total"] as? Int == 2)
        #expect(d?["active"] as? Int == 1)
        #expect(d?["completed"] as? Int == 1)   // total - active
        #expect(d?["flagged"] as? Int == 1)
        #expect(d?["urgent"] as? Int == 0)
        #expect(d?["overdue"] as? Int == 0)
        #expect(d?["lists"] as? Int == 1)
        #expect(d?["sections"] as? Int == 1)
        // key order is contractual: total, active, completed, overdue, flagged, urgent, lists, sections
        let keys = ["total", "active", "completed", "overdue", "flagged", "urgent", "lists", "sections"]
        var lastIdx = -1
        for k in keys {
            guard let idx = r.stdout.range(of: "\"\(k)\"")?.lowerBound else { Issue.record("missing key \(k)"); continue }
            let n = r.stdout.distance(from: r.stdout.startIndex, to: idx)
            #expect(n > lastIdx); lastIdx = n
        }
    }

    @Test func humanLayoutAndLabels() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["stats"], storeDir: dir)
        #expect(r.exit == 0)
        // uncolored (NO_COLOR) -> exact padded lines
        #expect(r.stdout.contains("Reminders Stats\n"))
        #expect(r.stdout.contains("  Total:      2\n"))
        #expect(r.stdout.contains("  Active:     1\n"))
        #expect(r.stdout.contains("  Completed:  1\n"))
        #expect(r.stdout.contains("  Overdue:    0\n"))   // zero prints plain "0"
        #expect(r.stdout.contains("  Flagged:    1\n"))
        #expect(r.stdout.contains("  Urgent:     0\n"))
        #expect(r.stdout.contains("  Lists:      1\n"))
        #expect(r.stdout.contains("  Sections:   1\n"))
    }
}
