import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// FlagTests – unit tests for the `flag` / `unflag` commands (P7).
//
// All tests drive `FlagCmd.performFlag` directly with fixture stores + mocks,
// mirroring the pattern established by DeleteTests / AddTests.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct FlagTests {

    // MARK: - Fixture helpers

    /// Build a fixture store. `build` seeds rows on a fresh Reminders schema.
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try build(db)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A store with a reminder: pk=5, ckid='CK5', title='Pay rent', list=10.
    private func withPayRent() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION)
                VALUES (10,3,'Bills',0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDREMINDER
                  (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER)
                VALUES (5,'Pay rent',10,1,0,'CK5')
            """)
        }
    }

    // MARK: - Primary path (private writer succeeds)

    @Test func flagViaPrivate() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()     // result status = "updated" by default
        let mockWriter  = MockWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: false,
            store: s, writer: mockWriter, private: mockPrivate)

        // Private writer called with correct args.
        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: true)])
        // EventKit writer NOT called (primary succeeded).
        #expect(mockWriter.calls.isEmpty)
        // Human output.
        #expect(out == WriteOutcome.ok("Flagged: Pay rent\n"))
    }

    @Test func unflagViaPrivate() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        let mockWriter  = MockWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: false, json: false,
            store: s, writer: mockWriter, private: mockPrivate)

        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: false)])
        #expect(mockWriter.calls.isEmpty)
        #expect(out == WriteOutcome.ok("Unflagged: Pay rent\n"))
    }

    // MARK: - JSON output

    @Test func flagJSON() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        let mockWriter  = MockWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: true,
            store: s, writer: mockWriter, private: mockPrivate)

        // Compact JSON: status, id (numeric Z_PK), title (raw ZTITLE).
        // serialized(indent:nil, ensureAscii:true) produces {"k": v} with one space after colon.
        #expect(out.stdout == #"{"status": "flagged", "id": 5, "title": "Pay rent"}"# + "\n")
        #expect(out.exitCode == 0)
    }

    @Test func unflagJSON() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        let mockWriter  = MockWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: false, json: true,
            store: s, writer: mockWriter, private: mockPrivate)

        #expect(out.stdout == #"{"status": "unflagged", "id": 5, "title": "Pay rent"}"# + "\n")
        #expect(out.exitCode == 0)
    }

    // MARK: - Fallback path (private fails → EventKit proxy)

    @Test func flagFallsBackToEventKit() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Private writer returns status "error" (not "updated") → triggers fallback.
        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "something went wrong")
        let mockWriter  = MockWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: false,
            store: s, writer: mockWriter, private: mockPrivate)

        // Private was still called.
        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: true)])
        // EventKit fallback called with flagged=true.
        #expect(mockWriter.calls.count == 1)
        if case let .update(id, w) = mockWriter.calls[0] {
            #expect(id == "CK5")
            #expect(w.flagged == true)
        } else {
            Issue.record("expected .update call, got \(mockWriter.calls[0])")
        }
        // Success output (fallback succeeded).
        #expect(out == WriteOutcome.ok("Flagged: Pay rent\n"))
    }

    @Test func unflagFallsBackToEventKit() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "rk unavailable")
        let mockWriter  = MockWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: false, json: false,
            store: s, writer: mockWriter, private: mockPrivate)

        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: false)])
        #expect(mockWriter.calls.count == 1)
        if case let .update(id, w) = mockWriter.calls[0] {
            #expect(id == "CK5")
            #expect(w.flagged == false)
        } else {
            Issue.record("expected .update call, got \(mockWriter.calls[0])")
        }
        #expect(out == WriteOutcome.ok("Unflagged: Pay rent\n"))
    }

    // MARK: - Both fail → refusal

    @Test func flagBothFailRefuses() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Private: status "error" (non-updated).
        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "rk down")
        // EventKit: throws.
        let mockWriter  = MockWriter()
        mockWriter.throwError = WriteError("ek write failed")

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 5, flagged: true, json: false,
                store: s, writer: mockWriter, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #5 ('Pay rent') while trying to flag it.\n")
        #expect(out.stdout.isEmpty)
    }

    @Test func unflagBothFailRefuses() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "rk down")
        let mockWriter  = MockWriter()
        mockWriter.throwError = WriteError("ek write failed")

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 5, flagged: false, json: false,
                store: s, writer: mockWriter, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #5 ('Pay rent') while trying to unflag it.\n")
    }

    // MARK: - Both fail with private throwing

    @Test func flagBothFailWhenPrivateThrows() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Private throws instead of returning error status.
        let mockPrivate = MockPrivateWriter()
        mockPrivate.throwError = WriteError("rk threw")
        let mockWriter  = MockWriter()
        mockWriter.throwError = WriteError("ek also threw")

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 5, flagged: true, json: false,
                store: s, writer: mockWriter, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Identifier-based writes failed"))
        #expect(out.stderr.contains("flag it"))
    }

    // MARK: - Not found

    @Test func flagNotFound() async throws {
        let (s, dir) = try store { _ in }   // empty store
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        let mockWriter  = MockWriter()

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 999, flagged: true, json: false,
                store: s, writer: mockWriter, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: #999 not found\n")
        #expect(mockPrivate.calls.isEmpty)
        #expect(mockWriter.calls.isEmpty)
    }

    @Test func unflagNotFound() async throws {
        let (s, dir) = try store { _ in }
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 1, flagged: false, json: false,
                store: s, writer: MockWriter(), private: MockPrivateWriter())
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: #1 not found\n")
    }

    // MARK: - NULL ckid refusal

    @Test func flagNoIdentifierRefuses() async throws {
        // Reminder with no ZCKIDENTIFIER (NULL ckid).
        let (s, dir) = try store { db in
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION)
                VALUES (1,3,'Home',0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDREMINDER
                  (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION)
                VALUES (7,'Buy milk',1,1,0)
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        let mockWriter  = MockWriter()

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 7, flagged: true, json: false,
                store: s, writer: mockWriter, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("no stable identifier"))
        #expect(out.stderr.contains("flag it"))
        #expect(out.stderr.contains("Buy milk"))
        // Neither writer should be called.
        #expect(mockPrivate.calls.isEmpty)
        #expect(mockWriter.calls.isEmpty)
    }

    @Test func unflagNoIdentifierRefuses() async throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
                INSERT INTO ZREMCDREMINDER
                  (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION)
                VALUES (8,'Loose item',1,0)
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 8, flagged: false, json: false,
                store: s, writer: MockWriter(), private: MockPrivateWriter())
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("no stable identifier"))
        #expect(out.stderr.contains("unflag it"))
    }

    // MARK: - Untitled reminder in both-fail message

    @Test func flagBothFailUntitledReminder() async throws {
        // Reminder with empty title → should show "(untitled)" in error.
        let (s, dir) = try store { db in
            try db.execute(sql: """
                INSERT INTO ZREMCDREMINDER
                  (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER)
                VALUES (3,'',1,0,'CK3')
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error")
        let mockWriter  = MockWriter()
        mockWriter.throwError = WriteError("ek fail")

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 3, flagged: true, json: false,
                store: s, writer: mockWriter, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("(untitled)"))
        #expect(out.stderr.contains("flag it"))
    }
}
