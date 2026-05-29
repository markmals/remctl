import Testing
import Foundation
import GRDB
@testable import RemindersControl

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
