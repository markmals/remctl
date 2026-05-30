import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// ListEditTests – unit tests for the `list-edit` command (P9).
//
// All tests drive `ListEdit.perform` directly with fixture stores + mocks.
// Fixture store layout:
//   - Regular list:  pk=10, 'Work',  Z_ENT=3, ZCKIDENTIFIER='L10'
//   - No-ckid list:  pk=11, 'NoCK',  Z_ENT=3, ZCKIDENTIFIER=NULL
//   - Twin lists:    pk=50, 'Twin',  Z_ENT=3, ZCKIDENTIFIER='L50'
//                    pk=51, 'Twin',  Z_ENT=3, ZCKIDENTIFIER='L51'
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct ListEditTests {

    // MARK: - Fixture helpers

    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            // Regular list: Work (Z_ENT=3)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (10, 3, 'Work', 'L10', 0)
            """)
            // List with NULL ckid
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZMARKEDFORDELETION)
                VALUES (11, 3, 'NoCK', 0)
            """)
            // Twin: two regular lists with the same name (ambiguous)
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

    // MARK: - renameOnly

    @Test func renameOnly() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: "Tasks", color: nil, symbol: nil, emoji: nil,
            groceries: false, standard: false, groceryLocale: nil,
            json: false, store: s, private: mock)

        // writer called with correct ckid and appearance containing the new name
        #expect(mock.calls.count == 1)
        if case .setListAppearance(let listId, let appearance) = mock.calls[0] {
            #expect(listId == "L10")
            #expect(appearance.name == "Tasks")
        } else {
            Issue.record("Expected setListAppearance call, got \(mock.calls[0])")
        }

        // human output: output_name = new-name
        #expect(out == WriteOutcome.ok("Updated list: Tasks\n"))
    }

    @Test func renameOnlyJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: "Tasks", color: nil, symbol: nil, emoji: nil,
            groceries: false, standard: false, groceryLocale: nil,
            json: true, store: s, private: mock)

        #expect(out.exitCode == 0)
        let data = Data(out.stdout.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["status"] as? String == "updated")
        #expect(obj["id"] as? Int == 10)
        #expect(obj["name"] as? String == "Tasks")
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "updated")
    }

    // MARK: - colorHexUpper / colorNameLower

    @Test func colorHexUpper() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: nil, color: "#aabbcc", symbol: nil, emoji: nil,
            groceries: false, standard: false, groceryLocale: nil,
            json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        if case .setListAppearance(_, let appearance) = mock.calls[0] {
            #expect(appearance.color == "#AABBCC")
        } else {
            Issue.record("Expected setListAppearance call")
        }
    }

    @Test func colorNameLower() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: nil, color: "RED", symbol: nil, emoji: nil,
            groceries: false, standard: false, groceryLocale: nil,
            json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        if case .setListAppearance(_, let appearance) = mock.calls[0] {
            #expect(appearance.color == "red")
        } else {
            Issue.record("Expected setListAppearance call")
        }
    }

    // MARK: - symbolAndEmojiBoth

    @Test func symbolAndEmojiBoth() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Work", listId: nil,
                newName: nil, color: nil, symbol: "folder", emoji: "🗂", // both set
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either --symbol or --emoji, not both.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - unknownSymbol

    @Test func unknownSymbol() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Work", listId: nil,
                newName: nil, color: nil, symbol: "notreal", emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Error: unsupported list symbol"))
        #expect(out.stderr.contains(WriteFormatting.pyRepr("notreal")))
        #expect(mock.calls.isEmpty)
    }

    // MARK: - groceriesAndStandard

    @Test func groceriesAndStandard() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Work", listId: nil,
                newName: nil, color: nil, symbol: nil, emoji: nil,
                groceries: true, standard: true, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either --groceries or --standard, not both.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - groceryKeyPresence

    @Test func groceryKeyPresenceGroceries() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: nil, color: nil, symbol: nil, emoji: nil,
            groceries: true, standard: false, groceryLocale: "en-US",
            json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        if case .setListAppearance(_, let appearance) = mock.calls[0] {
            #expect(appearance.shouldCategorizeGroceryItems == true)
            #expect(appearance.groceryLocaleID == "en_US")
        } else {
            Issue.record("Expected setListAppearance call")
        }
    }

    @Test func groceryKeyPresenceStandard() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: nil, color: nil, symbol: nil, emoji: nil,
            groceries: false, standard: true, groceryLocale: nil,
            json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        if case .setListAppearance(_, let appearance) = mock.calls[0] {
            #expect(appearance.shouldCategorizeGroceryItems == false)
            #expect(appearance.groceryLocaleID == nil)  // no locale key for standard
        } else {
            Issue.record("Expected setListAppearance call")
        }
    }

    // MARK: - noChange

    @Test func noChange() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Work", listId: nil,
                newName: nil, color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass at least one of --new-name, --color, --symbol, --emoji, --groceries, --standard, or --grocery-locale.\n")
        // Resolution is NOT reached; writer is NOT called.
        #expect(mock.calls.isEmpty)
    }

    // MARK: - outputNameWhenNoNewName

    @Test func outputNameWhenNoNewName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: nil, color: "blue", symbol: nil, emoji: nil,
            groceries: false, standard: false, groceryLocale: nil,
            json: false, store: s, private: mock)

        // output_name = resolved current title "Work" (NOT the input arg)
        #expect(out == WriteOutcome.ok("Updated list: Work\n"))
    }

    @Test func outputNameWhenNoNewNameJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await ListEdit.perform(
            name: "Work", listId: nil,
            newName: nil, color: "blue", symbol: nil, emoji: nil,
            groceries: false, standard: false, groceryLocale: nil,
            json: true, store: s, private: mock)

        #expect(out.exitCode == 0)
        let data = Data(out.stdout.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        // JSON name = resolved title "Work", not any new name
        #expect(obj["name"] as? String == "Work")
    }

    // MARK: - noCkidRefusal

    @Test func noCkidRefusal() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "NoCK", listId: nil,
                newName: "NewName", color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: target list has no stable CloudKit identifier.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - bothTargetError

    @Test func bothTargetError() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Work", listId: 10,
                newName: "NewName", color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either a list name or --list-id, not both.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - notFound

    @Test func notFound() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Ghost", listId: nil,
                newName: "NewName", color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: list not found: Ghost\n")
        #expect(mock.calls.isEmpty)
    }

    @Test func notFoundNoTarget() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: nil, listId: nil,
                newName: "NewName", color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass a list name or --list-id.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - ambiguous

    @Test func ambiguous() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Twin", listId: nil,
                newName: "NewName", color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr.hasPrefix("Error: multiple lists match 'Twin'. Use the exact list name or --list-id with one of:"))
        #expect(out.stderr.contains("50 (Twin)"))
        #expect(out.stderr.contains("51 (Twin)"))
        #expect(mock.calls.isEmpty)
    }

    // MARK: - writerFailure

    @Test func writerFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "boom")

        let out = await WriteDispatch.perform {
            try await ListEdit.perform(
                name: "Work", listId: nil,
                newName: "NewName", color: nil, symbol: nil, emoji: nil,
                groceries: false, standard: false, groceryLocale: nil,
                json: false, store: s, private: mock)
        }

        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: boom\n")
    }
}
