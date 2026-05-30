import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct AddTests {
    /// Build a fixture store. `build` seeds rows on a fresh Reminders schema.
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A store with a 'Work' list (id 10, ckid 'CK-W') for resolution tests.
    private func withWorkList() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
        }
    }

    /// Extract the single recorded `.create` ReminderWrite, or fail.
    private func createdWrite(_ m: MockWriter, sourceLocation: SourceLocation = #_sourceLocation) -> ReminderWrite? {
        guard m.calls.count == 1, case let .create(w) = m.calls[0] else {
            Issue.record("expected exactly one .create call, got \(m.calls)", sourceLocation: sourceLocation)
            return nil
        }
        return w
    }

    // A fixed reference date so due parsing is deterministic.
    private var fixedNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }  // 2023-11-14T...

    @Test func basicAddJSON() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(title: "Buy milk", json: true, store: s, writer: m)
        // Compact, key order status,id,title; numericId absent (no such row in fixture).
        #expect(out.stdout == #"{"status": "created", "id": "EK-NEW", "title": "Buy milk"}"# + "\n")
        #expect(out.exitCode == 0)
        let w = createdWrite(m)
        #expect(w?.title == "Buy milk")
        #expect(w?.due == nil)
    }

    @Test func basicAddHuman() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(title: "Buy milk", json: false, store: s, writer: m)
        #expect(out.stdout == "Created: Buy milk\n")
        #expect(out.exitCode == 0)
        #expect(m.calls.count == 1)
    }

    @Test func dueParsedSetsWrite() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", due: "tomorrow", json: false, store: s, writer: m, now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        let w = createdWrite(m)
        // The create call captured a non-nil .set(date) due.
        if case .set? = w?.due {} else { Issue.record("expected due == .set(date), got \(String(describing: w?.due))") }
    }

    @Test func badDueExitsTwoHuman() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", due: "notadate", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse due date"))
        #expect(m.calls.isEmpty)   // writer never reached
    }

    @Test func badDueExitsTwoJSON() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", due: "notadate", json: true, store: s, writer: m)
        }
        #expect(out.exitCode == 2)
        // JSON payload goes to stderr with the invalid_due_date code + input echo.
        #expect(out.stderr.contains(#""code": "invalid_due_date""#))
        #expect(out.stderr.contains(#""input": "notadate""#))
        #expect(out.stdout.isEmpty)
        #expect(m.calls.isEmpty)
    }

    @Test func priorityHigh() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", priority: "high", json: false, store: s, writer: m)
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.priority == 1)
    }

    @Test func badPriorityExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", priority: "bogus", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: priority must be high, medium, low, or none.\n")
        #expect(m.calls.isEmpty)
    }

    @Test func badRecurrenceExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", recurrence: "fortnightly", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("could not parse recurrence"))
        #expect(m.calls.isEmpty)
    }

    @Test func badAlarmExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", alarm: "soon", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: could not parse alarm 'soon'. Use 15m, 1h, 1d, or an absolute date.\n")
        #expect(m.calls.isEmpty)
    }

    @Test func recurrenceParses() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", recurrence: "daily", json: false, store: s, writer: m)
        #expect(createdWrite(m)?.recurrence == RecurrenceWrite(frequency: "daily", interval: 1))
    }

    @Test func alarmParses() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", alarm: "15m", json: false, store: s, writer: m)
        #expect(createdWrite(m)?.alarm == .relativeOffset(-900))
    }

    @Test func urlGoesToNotesAppendField() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", url: "https://x", json: false, store: s, writer: m)
        // Phase 2: --url sets ReminderWrite.url; the EventKitWriter appends it to notes.
        #expect(createdWrite(m)?.url == "https://x")
    }

    @Test func notesSet() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", notes: "remember", json: false, store: s, writer: m)
        #expect(createdWrite(m)?.notes == "remember")
    }

    @Test func listResolutionAddsResolvedListJSON() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(title: "T", list: "work", json: true, store: s, writer: m)
        // Resolved list name flows into the write.
        #expect(createdWrite(m)?.list == "Work")
        // case-insensitive method != exact, so resolvedList is emitted.
        #expect(out.stdout.contains(#""resolvedList": {"#))
        #expect(out.stdout.contains(#""requested": "work""#))
        #expect(out.stdout.contains(#""title": "Work""#))
        #expect(out.stdout.contains(#""id": 10"#))
        #expect(out.stdout.contains(#""method": "case_insensitive""#))
    }

    @Test func listResolutionAddsResolvedListHuman() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", list: "work", json: false, store: s, writer: m)
        #expect(out.stdout == "Created: T\nList: Work (resolved from work)\n")
    }

    @Test func exactListMatchOmitsResolvedList() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", list: "Work", json: false, store: s, writer: m)
        // Exact match: no "List:" line.
        #expect(out.stdout == "Created: T\n")
        #expect(createdWrite(m)?.list == "Work")
    }

    @Test func listNotFoundExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", list: "Nope", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("list not found"))
        #expect(m.calls.isEmpty)   // resolution failed before write
    }

    @Test func stubbedUrgentErrorsPhase3() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", urgent: true, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Phase 3"))
        #expect(out.stderr.contains("--urgent"))
        #expect(m.calls.isEmpty)
    }

    @Test func stubbedGroceryErrorsPhase3() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", grocery: true, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Phase 3"))
        #expect(out.stderr.contains("--grocery"))
        #expect(m.calls.isEmpty)
    }

    @Test func badDueBeatsStubFlag() async throws {
        // A bad due must surface as exit 2 even when a Phase-3 flag is also set.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", due: "notadate", grocery: true, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse due date"))
        #expect(m.calls.isEmpty)
    }

    @Test func titleRequiredEmpty() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "   ", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("title must not be empty"))
        #expect(m.calls.isEmpty)
    }

    @Test func numericIdReReadAppended() async throws {
        // When the created ZCKIDENTIFIER re-reads to a Z_PK, JSON gets numericId and human gets "ID: #".
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Home',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (77,'Buy milk',10,1,0,'EK-NEW')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let outH = try await Add.perform(title: "Buy milk", json: false, store: s, writer: m)
        #expect(outH.stdout == "Created: Buy milk\nID: #77\n")
        let m2 = MockWriter(); m2.resultID = "EK-NEW"
        let outJ = try await Add.perform(title: "Buy milk", json: true, store: s, writer: m2)
        #expect(outJ.stdout == #"{"status": "created", "id": "EK-NEW", "title": "Buy milk", "numericId": 77}"# + "\n")
    }
}
