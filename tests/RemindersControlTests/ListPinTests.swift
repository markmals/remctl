import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// ListPinTests – unit tests for the `list-pin` / `list-unpin` commands (P8).
//
// All tests drive `ListPin.performPin` directly with fixture stores + mocks.
// Fixture store layout:
//   - Regular list:   pk=10, 'Work',    Z_ENT=3, ZCKIDENTIFIER='L10'
//   - Smart list:     pk=20, 'Flagged', Z_ENT=4, ZCKIDENTIFIER='S20'
//   - Collision list: pk=30, 'Dup',     Z_ENT=3, ZCKIDENTIFIER='L30'
//   - Collision smart:pk=40, 'Dup',     Z_ENT=4, ZCKIDENTIFIER='S40'
//   - Twin lists:     pk=50, 'Twin',    Z_ENT=3; pk=51, 'Twin', Z_ENT=3
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct ListPinTests {

    // MARK: - Fixture helpers

    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            // Regular list: Work (Z_ENT=3)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (10, 3, 'Work', 'L10', 0)
            """)
            // Smart list: Flagged (Z_ENT=4) — uses ZSMARTLISTTYPE to activate smart-list path
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, ZSMARTLISTTYPE)
                VALUES (20, 4, 'Flagged', 'S20', 0, 'com.apple.reminders.smartlist.flagged')
            """)
            // Dup: exists as both a regular list AND a smart list (for both-match test)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (30, 3, 'Dup', 'L30', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, ZSMARTLISTTYPE)
                VALUES (40, 4, 'Dup', 'S40', 0, 'com.apple.reminders.smartlist.custom')
            """)
            // Twin: two regular lists with same name (ambiguous)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (50, 3, 'Twin', 'L50', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (51, 3, 'Twin', 'L51', 0)
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Store with a list that has NO ckid.
    private func storeNoCkid() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZMARKEDFORDELETION)
                VALUES (99, 3, 'NoCkid', 0)
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    // MARK: - Pin list by name

    @Test func pinListByName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: "Work", listId: nil, smartListId: nil,
            pinned: true, json: false, store: s, private: mock)

        #expect(mock.calls == [.setListPinned(listId: "L10", pinned: true)])
        #expect(out == WriteOutcome.ok("Pinned list: Work\n"))
    }

    // MARK: - Pin list by --list-id

    @Test func pinListByListId() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: nil, listId: 10, smartListId: nil,
            pinned: true, json: false, store: s, private: mock)

        #expect(mock.calls == [.setListPinned(listId: "L10", pinned: true)])
        #expect(out == WriteOutcome.ok("Pinned list: Work\n"))
    }

    // MARK: - Pin smart list by name

    @Test func pinSmartListByName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: "Flagged", listId: nil, smartListId: nil,
            pinned: true, json: false, store: s, private: mock)

        #expect(mock.calls == [.setSmartListPinned(smartListId: "S20", pinned: true)])
        #expect(out == WriteOutcome.ok("Pinned smart list: Flagged\n"))
    }

    // MARK: - Pin smart list by --smart-list-id

    @Test func pinSmartBySmartListId() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: nil, listId: nil, smartListId: 20,
            pinned: true, json: false, store: s, private: mock)

        #expect(mock.calls == [.setSmartListPinned(smartListId: "S20", pinned: true)])
        #expect(out == WriteOutcome.ok("Pinned smart list: Flagged\n"))
    }

    // MARK: - Unpin smart list with JSON output

    @Test func unpinSmartJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        // Default MockPrivateWriter result: status="updated", fields=[:], message=nil.
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: "Flagged", listId: nil, smartListId: nil,
            pinned: false, json: true, store: s, private: mock)

        #expect(out.exitCode == 0)
        // Parse the JSON output and check top-level keys.
        let data = Data(out.stdout.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["status"] as? String == "unpinned")
        #expect(obj["kind"] as? String == "smart-list")   // HYPHEN
        #expect(obj["id"] as? Int == 20)
        #expect(obj["name"] as? String == "Flagged")
        // The "private" sub-object must be present and have status="updated".
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "updated")
    }

    // MARK: - Error: both --list-id and --smart-list-id

    @Test func bothIdsError() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: nil, listId: 10, smartListId: 20,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either --list-id or --smart-list-id, not both.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - Error: no target given

    @Test func noTargetError() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: nil, listId: nil, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass a list/smart-list name, --list-id, or --smart-list-id.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - Error: name matches both a list and a smart list

    @Test func nameMatchesBoth() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: "Dup", listId: nil, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: 'Dup' matches both a list and a smart list. Use --list-id or --smart-list-id.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - Error: name matches neither

    @Test func nameMatchesNeither() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: "Ghost", listId: nil, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: list or smart list not found: Ghost\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - Error: ambiguous list fires first (before both-match check)

    @Test func ambiguousListFiresFirst() async throws {
        // 'Twin' → two regular lists (ambiguous). No smart list named 'Twin'.
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: "Twin", listId: nil, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        // The exact format: "Error: multiple lists match 'Twin'. Use the exact list name or --list-id with one of: 50 (Twin), 51 (Twin)"
        #expect(out.stderr.hasPrefix("Error: multiple lists match 'Twin'. Use the exact list name or --list-id with one of:"))
        #expect(out.stderr.contains("50 (Twin)"))
        #expect(out.stderr.contains("51 (Twin)"))
        #expect(mock.calls.isEmpty)
    }

    // MARK: - Error: no ckid (list)

    @Test func noCkidRefusal() async throws {
        let (s, dir) = try storeNoCkid(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: "NoCkid", listId: nil, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: target list has no stable CloudKit identifier.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - Error: writer failure

    @Test func writerFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "boom")

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: "Work", listId: nil, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: boom\n")
    }

    // MARK: - Unpin list by name (human output)

    @Test func unpinListByName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: "Work", listId: nil, smartListId: nil,
            pinned: false, json: false, store: s, private: mock)

        #expect(mock.calls == [.setListPinned(listId: "L10", pinned: false)])
        #expect(out == WriteOutcome.ok("Unpinned list: Work\n"))
    }

    // MARK: - JSON kind uses HYPHEN "smart-list", human label uses SPACE "smart list"

    @Test func kindHyphenVsLabelSpace() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        // Human output: "smart list" (space)
        let humanOut = try await ListPin.performPin(
            name: "Flagged", listId: nil, smartListId: nil,
            pinned: true, json: false, store: s, private: mock)
        #expect(humanOut.stdout == "Pinned smart list: Flagged\n")

        // JSON output: kind = "smart-list" (hyphen)
        let jsonOut = try await ListPin.performPin(
            name: "Flagged", listId: nil, smartListId: nil,
            pinned: true, json: true, store: s, private: mock)
        let data = Data(jsonOut.stdout.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["kind"] as? String == "smart-list")
    }

    // MARK: - smart list not found by id

    @Test func smartListNotFoundById() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: nil, listId: nil, smartListId: 999,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: smart list not found: id 999\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - list not found by id

    @Test func listNotFoundById() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListPin.performPin(
                name: nil, listId: 999, smartListId: nil,
                pinned: true, json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: list not found: id 999\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - JSON output includes private sub-object (list path)

    @Test func pinListJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListPin.performPin(
            name: "Work", listId: nil, smartListId: nil,
            pinned: true, json: true, store: s, private: mock)

        #expect(out.exitCode == 0)
        let data = Data(out.stdout.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["status"] as? String == "pinned")
        #expect(obj["kind"] as? String == "list")         // plain "list" not "smart-list"
        #expect(obj["id"] as? Int == 10)
        #expect(obj["name"] as? String == "Work")
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "updated")
    }
}
