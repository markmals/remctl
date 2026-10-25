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

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: false, store: s, private: mockPrivate)

        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: true)])
        #expect(out == WriteOutcome.ok("Flagged: Pay rent\n"))
    }

    @Test func unflagViaPrivate() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: false, json: false, store: s, private: mockPrivate)

        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: false)])
        #expect(out == WriteOutcome.ok("Unflagged: Pay rent\n"))
    }

    // MARK: - JSON output

    @Test func flagJSON() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: true, store: s, private: MockPrivateWriter())

        // Compact JSON: status, id (numeric Z_PK), title (raw ZTITLE).
        // serialized(indent:nil, ensureAscii:true) produces {"k": v} with one space after colon.
        #expect(out.stdout == #"{"status": "flagged", "id": 5, "title": "Pay rent"}"# + "\n")
        #expect(out.exitCode == 0)
    }

    @Test func unflagJSON() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: false, json: true, store: s, private: MockPrivateWriter())

        #expect(out.stdout == #"{"status": "unflagged", "id": 5, "title": "Pay rent"}"# + "\n")
        #expect(out.exitCode == 0)
    }

    // MARK: - Honest failure (no EventKit priority proxy, upstream c84fbca)

    @Test func flagFailsLoudlyWhenPrivateWriteFails() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Private writer returns status "error" (not "updated").
        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "something went wrong")

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: false, store: s, private: mockPrivate)

        #expect(mockPrivate.calls == [.setFlagged(id: "CK5", flagged: true)])
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == "Error: Could not flag #5 ('Pay rent'): something went wrong. "
            + "EventKit cannot set the real flagged state, so there is no fallback.\n")
    }

    @Test func unflagFailsLoudlyWhenPrivateWriteFails() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "rk unavailable")

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: false, json: false, store: s, private: mockPrivate)

        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr.contains("Could not unflag #5 ('Pay rent'): rk unavailable."))
    }

    @Test func flagFailureJSONIsStructured() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error", message: "rk down")

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: true, store: s, private: mockPrivate)

        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == #"{"status": "error", "code": "flag_failed", "id": 5, "message": "Could not flag #5 ('Pay rent'): rk down. EventKit cannot set the real flagged state, so there is no fallback."}"# + "\n")
    }

    @Test func flagFailsWhenPrivateThrows() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.throwError = WriteError("rk threw")

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: false, store: s, private: mockPrivate)

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Could not flag #5 ('Pay rent'): rk threw."))
    }

    @Test func flagFailureWithoutMessageUsesDefault() async throws {
        let (s, dir) = try withPayRent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error")

        let out = try await FlagCmd.performFlag(
            id: 5, flagged: true, json: false, store: s, private: mockPrivate)

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("private helper failed"))
    }

    // MARK: - Not found

    @Test func flagNotFound() async throws {
        let (s, dir) = try store { _ in }   // empty store
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 999, flagged: true, json: false, store: s, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: #999 not found\n")
        #expect(mockPrivate.calls.isEmpty)
    }

    @Test func unflagNotFound() async throws {
        let (s, dir) = try store { _ in }
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 1, flagged: false, json: false, store: s, private: MockPrivateWriter())
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

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 7, flagged: true, json: false, store: s, private: mockPrivate)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("no stable identifier"))
        #expect(out.stderr.contains("flag it"))
        #expect(out.stderr.contains("Buy milk"))
        #expect(mockPrivate.calls.isEmpty)
    }

    @Test func unflagNoIdentifierRefuses() async throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION)
                VALUES (1,3,'Home',0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDREMINDER
                  (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION)
                VALUES (8,'Loose item',1,1,0)
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = await WriteDispatch.perform {
            try await FlagCmd.performFlag(
                id: 8, flagged: false, json: false, store: s, private: MockPrivateWriter())
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("no stable identifier"))
        #expect(out.stderr.contains("unflag it"))
    }

    // MARK: - Untitled reminder in the failure message

    @Test func flagFailureShowsUntitledReminder() async throws {
        // Reminder with empty title → should show "(untitled)" in error.
        let (s, dir) = try store { db in
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION)
                VALUES (1,3,'Home',0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDREMINDER
                  (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER)
                VALUES (3,'',1,1,0,'CK3')
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockPrivate = MockPrivateWriter()
        mockPrivate.result = PrivateResult(status: "error")

        let out = try await FlagCmd.performFlag(
            id: 3, flagged: true, json: false, store: s, private: mockPrivate)

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("(untitled)"))
        #expect(out.stderr.contains("Could not flag #3"))
    }
}
