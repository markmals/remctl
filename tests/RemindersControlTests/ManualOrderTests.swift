import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `show` and subtask listings follow Reminders' persisted manual display order rather than
/// insertion order (upstream 5deddda, and the read half of 3eb076b for subtasks).
@Suite struct ManualOrderTests {
    /// List 10 holds three top-level reminders inserted 1,2,3 but ordered C,A in the record
    /// (B is unpositioned). #1 also has two subtasks whose order lives in the same record.
    private func fixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZREMINDERIDSMERGEABLEORDERING_V2_JSON)
            VALUES (10,3,'Work',0,'["CK-C","CK-A","CK-S2","CK-S1"]');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZPARENTREMINDER)
            VALUES (1,'A',10,1,0,0,'CK-A',NULL),
                   (2,'B',10,1,0,0,'CK-B',NULL),
                   (3,'C',10,1,0,0,'CK-C',NULL),
                   (4,'S1',10,1,0,0,'CK-S1',1),
                   (5,'S2',10,1,0,0,'CK-S2',1);
            """)
        }
    }

    @Test func showFollowsPersistedOrder() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        // Positioned rows first in record order; unpositioned rows keep query order afterwards.
        #expect(store.reminders(listPk: 10, topLevel: true, manualOrder: true)
                    .map { $0.string("ZTITLE")! } == ["C", "A", "B"])
        // Other reads stay on Z_PK order.
        #expect(store.reminders(listPk: 10, topLevel: true)
                    .map { $0.string("ZTITLE")! } == ["A", "B", "C"])
        let r = try CLIRunner.run(["show", "Work", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(arr?.compactMap { $0["title"] as? String } == ["C", "A", "B"])
    }

    @Test func subtasksFollowTheParentListOrder() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.reminders(completed: true, parentPk: 1).map { $0.string("ZTITLE")! } == ["S2", "S1"])
        let r = try CLIRunner.run(["subtasks", "1", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let subs = obj?["subtasks"] as? [[String: Any]]
        #expect(subs?.compactMap { $0["title"] as? String } == ["S2", "S1"])
    }

    @Test func missingOrderingRecordKeepsQueryOrder() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
            VALUES (1,'A',10,1,0,0,'CK-A'),(2,'B',10,1,0,0,'CK-B');
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.reminders(listPk: 10, topLevel: true, manualOrder: true)
                    .map { $0.string("ZTITLE")! } == ["A", "B"])
    }
}
