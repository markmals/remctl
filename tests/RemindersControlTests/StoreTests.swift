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
