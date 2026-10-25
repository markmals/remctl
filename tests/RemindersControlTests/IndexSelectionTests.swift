import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// Reminders indexes its deleted flag, and SQLite picked that index over the reminder-key
/// index whenever both columns were filtered, so each object lookup scanned every object
/// row (upstream b5d2a4f / issue #54). Every keyed lookup must stay on its key index.
@Suite struct IndexSelectionTests {
    /// Collects the SQL a store call actually runs, so these assertions test the query the
    /// planner sees rather than the text of a source file.
    private final class SQLLog: @unchecked Sendable {
        var lines: [String] = []
    }

    /// Core Data-shaped store with the indexes Reminders creates. The deleted-flag indexes are
    /// created last: that is the ordering under which SQLite prefers them to the key indexes.
    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            CREATE INDEX ZREMCDOBJECT_Z_ENT_INDEX ON ZREMCDOBJECT (Z_ENT);
            CREATE INDEX ZREMCDOBJECT_ZREMINDER_INDEX ON ZREMCDOBJECT (ZREMINDER);
            CREATE INDEX ZREMCDOBJECT_ZREMINDER1_INDEX ON ZREMCDOBJECT (ZREMINDER1);
            CREATE INDEX ZREMCDOBJECT_ZREMINDER2_INDEX ON ZREMCDOBJECT (ZREMINDER2);
            CREATE INDEX ZREMCDOBJECT_ZREMINDER3_INDEX ON ZREMCDOBJECT (ZREMINDER3);
            CREATE INDEX ZREMCDOBJECT_ZREMINDER4_INDEX ON ZREMCDOBJECT (ZREMINDER4);
            CREATE INDEX ZREMCDOBJECT_ZLIST_INDEX ON ZREMCDOBJECT (ZLIST);
            CREATE INDEX ZREMCDREMINDER_ZPARENTREMINDER_INDEX ON ZREMCDREMINDER (ZPARENTREMINDER);
            CREATE INDEX ZREMCDREMINDER_ZLIST_INDEX ON ZREMCDREMINDER (ZLIST);
            CREATE INDEX ZREMCDSAVEDATTACHMENT_ZREMINDER_INDEX ON ZREMCDSAVEDATTACHMENT (ZREMINDER);
            CREATE INDEX ZREMCDOBJECT_ZMARKEDFORDELETION_INDEX ON ZREMCDOBJECT (ZMARKEDFORDELETION);
            CREATE INDEX ZREMCDREMINDER_ZMARKEDFORDELETION_INDEX ON ZREMCDREMINDER (ZMARKEDFORDELETION);
            CREATE INDEX ZREMCDSAVEDATTACHMENT_ZMARKEDFORDELETION_INDEX ON ZREMCDSAVEDATTACHMENT (ZMARKEDFORDELETION);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION) VALUES (1,'x',10,1,0);
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Every query plan line produced by the statements `body` runs.
    private func plans(_ s: RemindersStore, _ body: () -> Void) throws -> [String] {
        let log = SQLLog()
        try s.queue.read { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event { log.lines.append(statement.expandedSQL) }
            }
        }
        body()
        try s.queue.read { db in db.trace(nil) }
        return try s.queue.read { db in
            try log.lines
                .filter { $0.uppercased().hasPrefix("SELECT") }
                .flatMap { try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \($0)").map { $0["detail"] ?? "" } }
        }
    }

    /// `detail` lines that search a table using an index, excluding the covering scans.
    private func searchedIndexes(_ plan: [String]) -> [String] {
        plan.filter { $0.contains("USING INDEX") }
    }

    @Test func keyedObjectLookupsStayOnTheirKeyIndex() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cases: [(name: String, index: String, run: () -> Void)] = [
            ("recurrence columns", "ZREMCDOBJECT_ZREMINDER4_INDEX", { _ = s.reminders(listPk: 10) }),
            ("rich link", "ZREMCDOBJECT_ZREMINDER2_INDEX", { _ = s.richLink(pk: 1) }),
            ("hashtags", "ZREMCDOBJECT_ZREMINDER3_INDEX", { _ = s.hashtags(pk: 1) }),
            ("alarms", "ZREMCDOBJECT_ZREMINDER_INDEX", { _ = s.alarms(pk: 1) }),
            ("absolute alarm", "ZREMCDOBJECT_ZREMINDER_INDEX", { _ = s.hasAbsoluteAlarm(pk: 1) }),
            ("assignment", "ZREMCDOBJECT_ZREMINDER1_INDEX", { _ = s.assignment(reminderPk: 1) }),
            ("sharees", "ZREMCDOBJECT_ZLIST_INDEX", { _ = s.sharees(listPk: 10) }),
            ("subtask count", "ZREMCDREMINDER_ZPARENTREMINDER_INDEX", { _ = s.subtaskCount(pk: 1) }),
            ("attachments", "ZREMCDSAVEDATTACHMENT_ZREMINDER_INDEX", { _ = s.attachments(pk: 1) }),
            ("batch preloads", "ZREMCDREMINDER_ZPARENTREMINDER_INDEX", { _ = s.preloadExtras([1]) }),
        ]
        for c in cases {
            let used = searchedIndexes(try plans(s, c.run))
            #expect(used.contains { $0.contains(c.index) }, "\(c.name) must search \(c.index); plan: \(used)")
            #expect(!used.contains { $0.contains("ZMARKEDFORDELETION_INDEX") },
                    "\(c.name) must not search the deleted-flag index; plan: \(used)")
        }
    }

    @Test func listReadsStayOnTheListIndex() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let used = searchedIndexes(try plans(s, { _ = s.reminders(listPk: 10, topLevel: true) }))
        #expect(used.contains { $0.contains("ZREMCDREMINDER_ZLIST_INDEX") }, "plan: \(used)")
        #expect(!used.contains { $0.contains("ZMARKEDFORDELETION_INDEX") }, "plan: \(used)")
    }
}
