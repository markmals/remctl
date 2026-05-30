import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct LinkTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Fixture: reminder pk 7, ckid 'XYZ', title 'Buy milk', in list 'Groceries'.
    private func withReminder() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (20,3,'Groceries',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (7,'Buy milk',20,1,0,'XYZ')")
        }
    }

    @Test func humanOutputIsExactURLForm() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = try Link.perform(id: 7, json: false, store: s)
        // cmd_link human form: `#<id> <title>` then a two-space-indented deep link.
        // The URL string is the parity-critical assertion.
        #expect(out.stdout == "#7 Buy milk\n  x-apple-reminderkit://REMCDReminder/XYZ\n")
        #expect(out.exitCode == 0)
    }

    @Test func jsonOutputHasExactKeysAndValues() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = try Link.perform(id: 7, json: true, store: s)
        // cmd_link per-item dict keys: id, title, link. Indent=2 like cmd_link's json.dumps.
        let expected = """
        {
          "id": 7,
          "title": "Buy milk",
          "link": "x-apple-reminderkit://REMCDReminder/XYZ"
        }
        """ + "\n"
        #expect(out.stdout == expected)
        #expect(out.exitCode == 0)
    }

    @Test func notFoundIsExitOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let out = await WriteDispatch.perform { try Link.perform(id: 7, json: false, store: s) }
        #expect(out.stderr == "Error: #7 not found\n")
        #expect(out.exitCode == 1)
    }

    @Test func noIdentifierRefuses() async throws {
        // ckid NULL -> the standard no-stable-identifier refusal (op "link it").
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION) VALUES (7,'Buy milk',1,0)")
        }; defer { try? FileManager.default.removeItem(at: dir) }
        let out = await WriteDispatch.perform { try Link.perform(id: 7, json: false, store: s) }
        #expect(out.stderr.contains("no stable identifier"))
        #expect(out.stderr.contains("link it"))
        #expect(out.stderr.contains("#7"))
        #expect(out.exitCode == 1)
    }
}
