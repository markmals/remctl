import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct ImportTests {
    /// Build a fixture store. `build` seeds rows on a fresh Reminders schema.
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A store with a 'Work' list so per-item list resolution succeeds when items name it.
    private func withWorkList() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
        }
    }

    /// A `readFile` closure returning the given JSON string's UTF-8 bytes for ANY path.
    private func reader(_ json: String) -> (String) -> Data? { { _ in Data(json.utf8) } }

    // A fixed reference date so due parsing is deterministic.
    private var fixedNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }  // 2023-11-14T...

    /// Count `.create` calls recorded on the mock.
    private func createCount(_ m: MockWriter) -> Int {
        m.calls.filter { if case .create = $0 { return true }; return false }.count
    }

    @Test func importBasic() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Buy milk"},{"title":"Walk dog"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 2)
        // Per-item human add success lines are present, then the summary with leading blank line.
        #expect(out.stdout.contains("Created: Buy milk\n"))
        #expect(out.stdout.contains("Created: Walk dog\n"))
        #expect(out.stdout.hasSuffix("\nImported 2/2 reminders (0 errors)\n"))
        #expect(out.stderr.isEmpty)
    }

    @Test func importJsonSummary() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Buy milk"},{"title":"Walk dog"}]"#),
            json: true, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 2)
        // stdout is ONE parseable summary line; per-item progress goes to stderr.
        #expect(out.stdout == #"{"status": "completed", "created": 2, "createdIds": ["EK-NEW", "EK-NEW"], "errors": [], "total": 2}"# + "\n")
        #expect(out.stderr.contains("imported index=0 id=EK-NEW\n"))
        #expect(out.stderr.contains("imported index=1 id=EK-NEW\n"))
        #expect(!out.stdout.contains("Imported"))
    }

    @Test func importRejectsDocumentWithTitlelessItemBeforeWriting() async throws {
        // A bad item ANYWHERE in the document blocks the whole import: nothing is created.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"A"},{},{"title":"C"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == """
            Error: Import validation failed; no reminders were created.
              Item 1: item requires a non-empty string title

            """)
    }

    @Test func importValidationErrorJsonPayload() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Good"},{"title":"Bad","due":"notadate"},{"title":"Worse","list":7}]"#),
            json: true, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == #"{"status": "error", "code": "invalid_import", "message": "Import validation failed; no reminders were created.", "created": 0, "createdIds": [], "errors": [{"index": 1, "message": "could not parse due date 'notadate'"}, {"index": 2, "message": "list must be a string"}], "total": 3}"# + "\n")
    }

    @Test func importReportsPartialWhenAWriteFails() async throws {
        // Validation passes, then the writer fails at runtime: created ids are reported,
        // the failure is indexed, and the exit code is non-zero.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.throwError = WriteError("List not found: Work")
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"A"}]"#),
            json: true, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(out.stdout == #"{"status": "partial", "created": 0, "createdIds": [], "errors": [{"index": 0, "title": "A", "message": "Error: List not found: Work"}], "total": 1}"# + "\n")
    }

    @Test func importAcceptsExportedRecurrenceObject() async throws {
        // An `export`-shaped recurrence object survives the round trip instead of being dropped.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let recurrence = #"{"frequency":"weekly","interval":2,"daysOfWeekDetailed":[{"weekNumber":0,"dayOfTheWeek":2}],"daysOfWeek":[2]}"#
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Standup","recurrence":\#(recurrence)}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        guard case let .create(w)? = m.calls.first else { Issue.record("no create"); return }
        #expect(w.recurrence == RecurrenceWrite(frequency: "weekly", interval: 2, daysOfWeek: [2], weekNumbers: [0]))
    }

    @Test func importRejectsInvalidRecurrenceObject() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Standup","recurrence":{}}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stderr.contains("Item 0: could not parse recurrence {}"))
        // A null recurrence is simply absent.
        let m2 = MockWriter()
        let out2 = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Standup","recurrence":null}]"#),
            json: false, store: s, writer: m2, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out2.exitCode == 0)
        guard case let .create(w)? = m2.calls.first else { Issue.record("no create"); return }
        #expect(w.recurrence == nil)
    }

    @Test func importDueWins() async throws {
        // Item with BOTH due+dueDate: due ("tomorrow") wins over dueDate ("2020-01-01").
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Both","due":"tomorrow","dueDate":"2020-01-01"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 1)
        guard case let .create(w) = m.calls[0], case let .set(date)? = w.due else {
            Issue.record("expected a .create with .set(due)"); return
        }
        // "tomorrow" relative to fixedNow is in 2023, NOT the 2020-01-01 dueDate value.
        let cal = Calendar.current
        #expect(cal.component(.year, from: date) == 2023)

        // And an item with ONLY dueDate parses its due from dueDate.
        let m2 = MockWriter()
        let out2 = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"OnlyDD","dueDate":"tomorrow"}]"#),
            json: false, store: s, writer: m2, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out2.exitCode == 0)
        guard case let .create(w2) = m2.calls[0], case .set? = w2.due else {
            Issue.record("expected dueDate to populate due"); return
        }
    }

    @Test func importPriorityString() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"P","priority":"high"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 1)
        guard case let .create(w) = m.calls[0] else { Issue.record("no create"); return }
        #expect(w.priority == 1)
    }

    @Test func importPriorityMustBeAString() async throws {
        // An int priority is a document error, caught before anything is written.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"P","priority":1}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stderr.contains("Item 0: priority must be a string"))
    }

    @Test func importRejectsUnknownPriorityName() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"P","priority":"urgent"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stderr.contains("Item 0: priority must be high, medium, low, or none"))
    }

    @Test func importRejectsNonBooleanFlagged() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"P","flagged":"yes"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stderr.contains("Item 0: flagged must be a boolean"))
    }

    @Test func importRejectsUnparseableAlarm() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"P","alarm":"whenever"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stderr.contains("Item 0: could not parse alarm 'whenever'"))
    }

    @Test func importFlaggedItemWritesRealFlag() async throws {
        // Add's --flag implies the private path, so an imported flagged:true item is created by
        // EventKit and then flagged for real through the private writer.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let mp = MockPrivateWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"X","flagged":true}]"#),
            json: false, store: s, writer: m, private: mp, now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 1)
        #expect(mp.calls == [.setFlagged(id: "EK-NEW", flagged: true)])
        #expect(out.stdout.hasSuffix("\nImported 1/1 reminders (0 errors)\n"))
    }

    @Test func importBadDueInLaterItemWritesNothing() async throws {
        // The good FIRST item must not be created when a later item fails validation.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Good"},{"title":"Bad","due":"notadate"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr.contains("Item 1: could not parse due date 'notadate'"))
    }

    @Test func importFileNotFound() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: { _ in nil },                // file absent
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: File 'x.json' not found\n")
        #expect(m.calls.isEmpty)
    }

    @Test func importUnreadableFileFailsWithJsonError() async throws {
        // When a file EXISTS but cannot be read (simulated by returning Data() — empty bytes),
        // the error must be "Failed to read JSON: ..." NOT "File '...' not found".
        // This matches Python's IOError path (remctl:6328-6336) vs the not-found path.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "/some/existing/but/unreadable.json",
            readFile: { _ in Data() },             // file exists but unreadable → empty bytes sentinel
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(out.stderr.hasPrefix("Error: Failed to read JSON: "))
        #expect(!out.stderr.contains("not found"))
        #expect(m.calls.isEmpty)
    }

    @Test func importNonObjectElementsAreDocumentErrors() async throws {
        // Non-object array elements are reported per index and block the whole import, so the
        // one valid object ("Good") is NOT created either.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[1, "x", null, {"title":"Good"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        for index in 0...2 { #expect(out.stderr.contains("Item \(index): item must be an object")) }
    }

    @Test func importBadJson() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: { _ in Data("{not json".utf8) },
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        // Only the prefix is guaranteed (Swift's decode-error text diverges from Python's).
        #expect(out.stderr.hasPrefix("Error: Failed to read JSON: "))
        #expect(m.calls.isEmpty)
    }

    @Test func importNotArray() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"{"title":"x"}"#),    // a top-level object, not an array
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: JSON must be an array of reminder objects\n")
        #expect(m.calls.isEmpty)
    }

    @Test func importEmptyArray() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader("[]"),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "\nImported 0/0 reminders (0 errors)\n")
        #expect(m.calls.isEmpty)
    }
}
