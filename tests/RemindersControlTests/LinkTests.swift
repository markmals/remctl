import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct LinkTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Fixture lists + reminders:
    ///   list 20 'Work':      pk 7 ckid 'CK7' 'Buy milk', pk 8 ckid 'CK8' 'Call Bob'
    ///   list 21 'Personal':  pk 9 ckid NULL 'No link', pk 10 ckid 'CK10' 'Café crème' (subtask of 7)
    private func withFixture() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (20,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (21,3,'Personal',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZCOMPLETED) VALUES (7,'Buy milk',20,1,0,'CK7',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZCOMPLETED) VALUES (8,'Call Bob',20,1,0,'CK8',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZCOMPLETED) VALUES (9,'No link',21,1,0,NULL,0)")
            // pk 10 is a subtask of pk 7 (NOT top-level) -> excluded from a list query's top_level=true.
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZCOMPLETED,ZPARENTREMINDER) VALUES (10,'Café crème',21,1,0,'CK10',0,7)")
        }
    }

    private let noAnsi = Ansi.resolve(noColorFlag: true)

    @Test func linkMultipleIds() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // Human: two lines per result.
        let human = try Link.perform(ids: [7, 8], list: nil, listId: nil, completed: false,
                                     json: false, store: s, ansi: noAnsi)
        #expect(human.stdout == """
        #7 Buy milk
          x-apple-reminderkit://REMCDReminder/CK7
        #8 Call Bob
          x-apple-reminderkit://REMCDReminder/CK8

        """)
        #expect(human.stderr.isEmpty)
        #expect(human.exitCode == 0)

        // JSON: array of two {id,title,link} objects.
        let json = try Link.perform(ids: [7, 8], list: nil, listId: nil, completed: false,
                                    json: true, store: s, ansi: noAnsi)
        #expect(json.stdout == """
        [
          {
            "id": 7,
            "title": "Buy milk",
            "link": "x-apple-reminderkit://REMCDReminder/CK7"
          },
          {
            "id": 8,
            "title": "Call Bob",
            "link": "x-apple-reminderkit://REMCDReminder/CK8"
          }
        ]
        """ + "\n")
        #expect(json.exitCode == 0)
    }

    @Test func linkNullCkidSilentlyOmitted() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // pk 9 has a NULL ckid -> omitted from BOTH human and JSON, with no error/warning.
        let human = try Link.perform(ids: [7, 9], list: nil, listId: nil, completed: false,
                                     json: false, store: s, ansi: noAnsi)
        #expect(human.stdout == "#7 Buy milk\n  x-apple-reminderkit://REMCDReminder/CK7\n")
        #expect(!human.stdout.contains("No link"))
        #expect(!human.stdout.contains("#9"))
        #expect(human.stderr.isEmpty)   // NULL ckid is NOT a warning
        #expect(human.exitCode == 0)

        let json = try Link.perform(ids: [7, 9], list: nil, listId: nil, completed: false,
                                    json: true, store: s, ansi: noAnsi)
        #expect(!json.stdout.contains("No link"))
        #expect(json.stderr.isEmpty)
        // Exactly one object in the array.
        #expect(json.stdout == """
        [
          {
            "id": 7,
            "title": "Buy milk",
            "link": "x-apple-reminderkit://REMCDReminder/CK7"
          }
        ]
        """ + "\n")
    }

    @Test func linkNotFoundWarnsContinues() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // #999 is missing -> warns to stderr (non-fatal), exit 0, #7 still output.
        let out = try Link.perform(ids: [7, 999], list: nil, listId: nil, completed: false,
                                   json: false, store: s, ansi: noAnsi)
        #expect(out.stderr.contains("Warning: #999 not found"))
        #expect(out.exitCode == 0)
        #expect(out.stdout == "#7 Buy milk\n  x-apple-reminderkit://REMCDReminder/CK7\n")
    }

    @Test func linkBothIdsAndList() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = await WriteDispatch.perform {
            try Link.perform(ids: [7], list: "Work", listId: nil, completed: false,
                             json: false, store: s, ansi: noAnsi)
        }
        #expect(out.stderr == "Error: pass reminder IDs or a list target, not both.\n")
        #expect(out.exitCode == 1)
    }

    @Test func linkNoneSpecified() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // No ids and no list target. cmd_link prints this WITHOUT an "Error: " prefix.
        let out = await WriteDispatch.perform {
            try Link.perform(ids: [], list: nil, listId: nil, completed: false,
                             json: false, store: s, ansi: noAnsi)
        }
        #expect(out.stderr == "No reminders specified.\n")
        #expect(out.exitCode == 1)
    }

    @Test func linkByList() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // --list Work -> the list's top-level reminders (pk 7, 8). pk 10 (subtask) is in Personal anyway.
        let out = try Link.perform(ids: [], list: "Work", listId: nil, completed: false,
                                   json: false, store: s, ansi: noAnsi)
        #expect(out.stdout == """
        #7 Buy milk
          x-apple-reminderkit://REMCDReminder/CK7
        #8 Call Bob
          x-apple-reminderkit://REMCDReminder/CK8

        """)
        #expect(out.exitCode == 0)

        // Personal: only pk 10 is in the list, BUT it's a subtask (top_level=false) so it's excluded,
        // and pk 9 has a NULL ckid so it's omitted -> empty output, empty JSON array.
        let personalJson = try Link.perform(ids: [], list: "Personal", listId: nil, completed: false,
                                            json: true, store: s, ansi: noAnsi)
        #expect(personalJson.stdout == "[]\n")
        #expect(personalJson.exitCode == 0)
    }

    @Test func linkJsonArrayExact() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // Exact JSON: a top-level array, indent=2, keys id/title/link only (no _list_name).
        let out = try Link.perform(ids: [7], list: nil, listId: nil, completed: false,
                                   json: true, store: s, ansi: noAnsi)
        #expect(out.stdout == """
        [
          {
            "id": 7,
            "title": "Buy milk",
            "link": "x-apple-reminderkit://REMCDReminder/CK7"
          }
        ]
        """ + "\n")
        #expect(!out.stdout.contains("_list_name"))
        #expect(!out.stdout.contains("list_name"))
    }

    @Test func linkJsonEnsureAsciiEscapesNonAscii() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // pk 10 title 'Café crème' — cmd_link uses json.dumps(..., indent=2) with ensure_ascii=TRUE,
        // so the non-ASCII chars must be \uXXXX-escaped. Query pk 10 directly by id.
        let out = try Link.perform(ids: [10], list: nil, listId: nil, completed: false,
                                   json: true, store: s, ansi: noAnsi)
        // ensure_ascii=true -> é/è are escaped as é / è; the literal chars must NOT appear.
        #expect(out.stdout.contains(#""title": "Caf\u00e9 cr\u00e8me""#))
        #expect(!out.stdout.contains("\u{00e9}"))   // literal non-ASCII must NOT appear
        #expect(!out.stdout.contains("\u{00e8}"))
    }

    @Test func linkUrlExact() async throws {
        let (s, dir) = try withFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = try Link.perform(ids: [7], list: nil, listId: nil, completed: false,
                                   json: true, store: s, ansi: noAnsi)
        // The link is exactly x-apple-reminderkit://REMCDReminder/<ckid>.
        #expect(out.stdout.contains(#""link": "x-apple-reminderkit://REMCDReminder/CK7""#))
    }
}
