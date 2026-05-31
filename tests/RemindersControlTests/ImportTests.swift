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
        // aa.json=false per item: the human add lines are STILL in the buffer before the JSON summary.
        #expect(out.stdout.contains("Created: Buy milk\n"))
        #expect(out.stdout.contains("Created: Walk dog\n"))
        // Compact one-line JSON summary as the final line.
        #expect(out.stdout.hasSuffix(#"{"created": 2, "errors": 0, "total": 2}"# + "\n"))
        // No human "Imported" summary in JSON mode.
        #expect(!out.stdout.contains("Imported"))
    }

    @Test func importSkipNoTitle() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"A"},{},{"title":"C"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 2)               // middle item skipped
        #expect(out.stderr.contains("Warning: Skipping item without title"))
        // total counts ALL elements (incl. the skipped one); note literal "1 errors" (not singular).
        #expect(out.stdout.hasSuffix("\nImported 2/3 reminders (1 errors)\n"))
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

    @Test func importPriorityIntFails() async throws {
        // An int priority (1) is stringified to "1" → Add's priority parse fails → item errors.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"P","priority":1}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)                 // import main path always exits 0
        #expect(createCount(m) == 0)               // not created
        #expect(out.stdout.hasSuffix("\nImported 0/1 reminders (1 errors)\n"))
        #expect(out.stderr.contains("priority must be high, medium, low, or none."))
    }

    @Test func importFlaggedItemUsesPublicProxy() async throws {
        // P12 consequence: Add's --flag ALONE routes through the PUBLIC EventKit priority-proxy
        // (no private-only flag is set during import → wantsPrivate is false), so a flagged:true
        // item is now CREATED (write.flagged == true) rather than erroring. The private writer is
        // threaded through but never invoked.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let mp = MockPrivateWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"X","flagged":true}]"#),
            json: false, store: s, writer: m, private: mp, now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 1)               // item created via the public flag-proxy
        #expect(mp.calls.isEmpty)                  // private writer NOT invoked
        if case let .create(w)? = m.calls.first { #expect(w.flagged == true) }
        #expect(out.stdout.hasSuffix("\nImported 1/1 reminders (0 errors)\n"))
    }

    @Test func importItemBadDueContinues() async throws {
        // One good item + one with a bad due: the good one is created, the bad one errors,
        // and the loop never aborts (import exit 0).
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[{"title":"Good"},{"title":"Bad","due":"notadate"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 1)
        #expect(out.stdout.contains("Created: Good\n"))
        #expect(out.stdout.hasSuffix("\nImported 1/2 reminders (1 errors)\n"))
        #expect(out.stderr.contains("could not parse due date"))
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

    @Test func importNonObjectElementsSkipped() async throws {
        // Non-object array elements (int, string, null) are treated as title-less: each emits
        // "Warning: Skipping item without title" and increments errors. The one valid object-with-title
        // ("Good") is still created. Array: [1, "x", null, {"title":"Good"}] → 1 created, 3 errors.
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await Import.perform(
            path: "x.json",
            readFile: reader(#"[1, "x", null, {"title":"Good"}]"#),
            json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(createCount(m) == 1)
        #expect(out.stdout.hasSuffix("\nImported 1/4 reminders (3 errors)\n"))
        // Each of the 3 non-object elements emits its own warning line.
        let warningCount = out.stderr.components(separatedBy: "Warning: Skipping item without title").count - 1
        #expect(warningCount == 3)
        #expect(out.stderr.contains("Warning: Skipping item without title"))
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
