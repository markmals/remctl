import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct RemColsTests {
    @Test func remColsHasExactAliasesAndNoNewlines() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let cols = store.remCols()
        #expect(!cols.contains("\n"))
        #expect(cols.contains("r.ZDUEDATE AS ZDUEDATE"))
        #expect(cols.contains("l.ZNAME as list_name"))
        #expect(cols.contains("r.ZISURGENTSTATEENABLEDFORCURRENTUSER AS ZISURGENTSTATEENABLEDFORCURRENTUSER"))
        #expect(cols.contains("AS recurrence_frequency"))
        #expect(cols.contains("AS recurrence_interval"))
        #expect(cols.contains("AS recurrence_set_positions"))
        #expect(cols.contains("rr.ZREMINDER4 = r.Z_PK"))
        #expect(cols.contains("rr.Z_ENT = 34"))
        // it must be valid SQL: run it against the fixture (no rows, but must parse)
        let ran = try store.queue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK)") ?? -1
        }
        #expect(ran == 0)
    }
    @Test func urgentFallsBackToZeroWhenColumnMissing() throws {
        let dir = try FixtureDB.tempStore { db in
            try db.execute(sql: "CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZNOTES TEXT, ZCOMPLETED INTEGER, ZFLAGGED INTEGER, ZPRIORITY INTEGER, ZDUEDATE REAL, ZALLDAY INTEGER, ZCOMPLETIONDATE REAL, ZCREATIONDATE REAL, ZPARENTREMINDER INTEGER, ZLIST INTEGER, ZICSURL TEXT, ZCKIDENTIFIER TEXT, ZMARKEDFORDELETION INTEGER, ZACCOUNT INTEGER); CREATE TABLE ZREMCDBASELIST (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT); CREATE TABLE ZREMCDOBJECT (Z_PK INTEGER PRIMARY KEY, ZREMINDER4 INTEGER, ZMARKEDFORDELETION INTEGER, Z_ENT INTEGER, ZFREQUENCY INTEGER, ZINTERVAL INTEGER, ZOCCURRENCECOUNT INTEGER, ZENDDATE REAL, ZDAYSOFTHEWEEK TEXT, ZDAYSOFTHEMONTH TEXT, ZMONTHSOFTHEYEAR TEXT, ZDAYSOFTHEYEAR TEXT, ZWEEKSOFTHEYEAR TEXT, ZSETPOSITIONS TEXT);")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.remCols().contains("0 AS ZISURGENTSTATEENABLEDFORCURRENTUSER"))
        #expect(store.remCols().contains("NULL AS ZDUEDATEDELTAALERTSDATA"))
        #expect(store.remCols().contains("NULL AS ZDISPLAYDATEDATE"))
    }
}

@Suite struct ReminderQueryTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }
    @Test func topLevelExcludesCompletedAndChildren() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER) VALUES (1,'top',10,1,0,0,NULL);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER) VALUES (2,'done',10,1,1,0,NULL);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER) VALUES (3,'child',10,1,0,0,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = s.reminders(listPk: 10, completed: false, topLevel: true)
        #expect(rows.map { $0.int("Z_PK")! } == [1])  // 2 completed, 3 is a child -> excluded
    }
    @Test func remindersWithCompletedTrueIncludesDone() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (1,'a',1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (2,'b',1,1,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.reminders(completed: true).map { $0.int("Z_PK")! }.sorted() == [1,2])
    }
    @Test func reminderByPkFiltersDeletedAndNullAccount() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (1,'ok',1,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (2,'del',1,1);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (3,'noacct',NULL,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.reminder(pk: 1)?.string("ZTITLE") == "ok")
        #expect(s.reminder(pk: 2) == nil)
        #expect(s.reminder(pk: 3) == nil)
    }
    @Test func reminderByIdentifierIsCaseInsensitiveNewestWins() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (1,'old',1,0,'abc');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (5,'new',1,0,'ABC');
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.reminder(identifier: "AbC")?.int("Z_PK") == 5)  // newest Z_PK
        #expect(s.reminder(identifier: "") == nil)
    }
    @Test func subtaskCountCountsActiveChildrenOnly() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZACCOUNT,ZMARKEDFORDELETION,ZPARENTREMINDER,ZCOMPLETED) VALUES (2,1,0,1,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZACCOUNT,ZMARKEDFORDELETION,ZPARENTREMINDER,ZCOMPLETED) VALUES (3,1,0,1,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.subtaskCount(pk: 1) == 1)  // one active child (3 is completed)
    }
}

@Suite struct ReadQueryTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }
    // A reminder must belong to a list (l.Z_PK IS NOT NULL) — insert a list 10 in each fixture.
    @Test func searchEscapesPercentLiteral() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME) VALUES (10,3,'L');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (1,'100% done',10,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (2,'plain',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // literal '%' must match only the title containing '%', NOT match-all
        #expect(s.search("%").map { $0.int("Z_PK")! } == [1])
    }
    @Test func searchExcludesCompletedByDefault() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME) VALUES (10,3,'L');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (1,'milk',10,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (2,'milk done',10,1,1,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.search("milk").map { $0.int("Z_PK")! } == [1])
        #expect(Set(s.search("milk", completed: true).map { $0.int("Z_PK")! }) == [1,2])
    }
    @Test func flaggedOrdersDueNullsLast() throws {
        // due epoch values: r1 has due, r2 has NULL due -> r1 before r2
        let due = AppleEpoch.toTs(Date(timeIntervalSince1970: 978307200 + 1000))
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME) VALUES (10,3,'L');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZFLAGGED,ZDUEDATE) VALUES (1,'has-due',10,1,0,0,1,\(due));
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZFLAGGED,ZDUEDATE) VALUES (2,'no-due',10,1,0,0,1,NULL);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZFLAGGED) VALUES (3,'unflagged',10,1,0,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.flagged().map { $0.int("Z_PK")! } == [1,2])  // 3 excluded; due NULLS LAST -> 1 then 2
    }
    @Test func dueTodayIncludesOverduePastItems() throws {
        // now = fixed; an item due yesterday is included when includeOverdue (default)
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 12))!
        let yesterday = AppleEpoch.toTs(cal.date(byAdding: .day, value: -1, to: now)!)
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME) VALUES (10,3,'L');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE) VALUES (1,'overdue',10,1,0,0,\(yesterday));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.dueToday(includeOverdue: true, now: now).map { $0.int("Z_PK")! } == [1])
        #expect(s.dueToday(includeOverdue: false, now: now).isEmpty)  // not in [sod, eod)
    }
    @Test func urgentMatchesUrgentColumn() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME) VALUES (10,3,'L');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZISURGENTSTATEENABLEDFORCURRENTUSER) VALUES (1,'u',10,1,0,0,1);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZISURGENTSTATEENABLEDFORCURRENTUSER) VALUES (2,'n',10,1,0,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.urgent().map { $0.int("Z_PK")! } == [1])
    }
}

@Suite struct StoreOpenTests {
    @Test func opensReadOnlyAndProbesColumns() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.reminderHasColumn("ZISURGENTSTATEENABLEDFORCURRENTUSER"))
        #expect(!store.reminderHasColumn("ZNOPE"))
        #expect(store.tableColumnNames("ZREMCDBASELIST").contains("ZSMARTLISTTYPE"))
    }
    @Test func writeIsRejectedOnReadonly() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(throws: (any Error).self) {
            try store.queue.write { try $0.execute(sql: "INSERT INTO ZREMCDHASHTAGLABEL(ZNAME) VALUES('x')") }
        }
    }
    @Test func rowAccessorsTolerateMissingAndNullColumns() throws {
        let q = try FixtureDB.inMemory { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZNOTES, ZACCOUNT) VALUES (1, 'hi', NULL, 1)")
        }
        let row = try q.read { try Row.fetchOne($0, sql: "SELECT Z_PK, ZTITLE, ZNOTES FROM ZREMCDREMINDER WHERE Z_PK = 1")! }
        #expect(row.int("Z_PK") == 1)
        #expect(row.string("ZTITLE") == "hi")
        #expect(row.string("ZNOTES") == nil)        // NULL column -> nil
        #expect(row.has("ZTITLE") == true)
        #expect(row.has("ZABSENT") == false)         // not selected -> nil/false
        #expect(row.string("ZABSENT") == nil)
    }
}
