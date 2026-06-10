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
    @Test func allDayBucketsByDisplayDateNotSyntheticDue() throws {
        // Reminders stores all-day ZDUEDATE at UTC midnight, which west of UTC lands on the
        // previous local day. Due-window bucketing must follow ZDISPLAYDATEDATE for all-day items.
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 12))!
        let synthDue = AppleEpoch.toTs(cal.date(byAdding: .day, value: -1, to: now)!)  // "yesterday"
        let displayToday = AppleEpoch.toTs(cal.startOfDay(for: now))                    // today 00:00 local
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME) VALUES (10,3,'L');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE,ZDISPLAYDATEDATE) VALUES (1,'allday',10,1,0,0,1,\(synthDue),\(displayToday));
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE) VALUES (2,'timed',10,1,0,0,0,\(synthDue));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // All-day item buckets to today by its display date — not overdue by its synthetic due.
        #expect(s.dueToday(includeOverdue: false, now: now).map { $0.int("Z_PK")! } == [1])
        // The timed item (real due yesterday) is genuinely overdue; the all-day item is not.
        #expect(s.overdue(now: now).map { $0.int("Z_PK")! } == [2])
    }
}

@Suite struct ExtrasQueryTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }
    @Test func hashtagsForReminder() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDHASHTAGLABEL (Z_PK,ZNAME) VALUES (1,'work'),(2,'home');
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER3,ZHASHTAGLABEL) VALUES (10,42,1),(11,42,2);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.hashtags(pk: 42) == ["work","home"])  // row order
        #expect(s.hashtags(pk: 99) == [])
    }
    @Test func attachmentsUnionImageAndFile() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZUTI,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION) VALUES (1,42,'a.pdf','com.adobe.pdf','file',0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZUTI,ZWIDTH,ZHEIGHT,ZMARKEDFORDELETION) VALUES (2,42,'b.png','public.png',100,100,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = s.attachments(pk: 42)
        // ORDER BY ZFILENAME -> a.pdf, b.png
        #expect(rows.map { $0.string("ZFILENAME")! } == ["a.pdf","b.png"])
        #expect(rows[0].string("ZATTACHMENTTYPERAWVALUE") == "file")
        #expect(rows[1].string("ZATTACHMENTTYPERAWVALUE") == "image")  // derived from ZWIDTH/ZHEIGHT
    }
    @Test func alarmsRelativeTriggerJoin() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            -- alarm object (Z_ENT=15) referencing a trigger object via ZTRIGGER
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (5,15,42,6,0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZTIMEINTERVAL,ZMARKEDFORDELETION) VALUES (6,-600,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = s.alarms(pk: 42)
        #expect(rows.count == 1)
        #expect(rows[0].int("alarm_id") == 5)
        #expect(rows[0].double("time_interval") == -600)
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
    @Test func openRejectsForeignSchema() throws {
        // A sqlite DB without ZREMCDREMINDER is not a Reminders store (port upstream aba7cf5).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = try DatabaseQueue(path: dir.appendingPathComponent("Data-x.sqlite").path)
        try q.write { try $0.execute(sql: "CREATE TABLE NOTREMINDERS (id INTEGER)") }
        #expect {
            _ = try RemindersStore.open(storeDir: dir)
        } throws: { error in
            (error as? RemindersDBUnavailable)?.message.contains("ZREMCDREMINDER") == true
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
