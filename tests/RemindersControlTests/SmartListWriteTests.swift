import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// SmartListWriteTests – unit tests for smart-list-create / edit / delete (P16).
//
// All tests drive the `perform` cores directly with a fixture store + MockPrivateWriter.
// Fixture store layout (all custom smart lists, ZSMARTLISTTYPE = custom):
//   - pk=30, 'High Priority', ZCKIDENTIFIER='SL30', ZFILTERDATA={"flagged":true}
//   - pk=40, 'Dup',           ZCKIDENTIFIER='SL40'   (ambiguous twin)
//   - pk=41, 'Dup',           ZCKIDENTIFIER='SL41'   (ambiguous twin)
//   - pk=50, 'NoCkid',        ZCKIDENTIFIER=NULL     (no stable identifier)
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct SmartListWriteTests {

    private static let customType = "com.apple.reminders.smartlist.custom"

    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            // pk=30 High Priority with a flagged filter blob (so edit can preserve it).
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, ZSMARTLISTTYPE, ZFILTERDATA)
                VALUES (30, 4, 'High Priority', 'SL30', 0, ?, ?)
            """, arguments: [Self.customType, Data(#"{"flagged":true}"#.utf8)])
            // pk=40 / pk=41 'Dup' — ambiguous exact-name match.
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, ZSMARTLISTTYPE)
                VALUES (40, 4, 'Dup', 'SL40', 0, ?)
            """, arguments: [Self.customType])
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, ZSMARTLISTTYPE)
                VALUES (41, 4, 'Dup', 'SL41', 0, ?)
            """, arguments: [Self.customType])
            // pk=50 NoCkid — custom smart list with NULL ckid.
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZMARKEDFORDELETION, ZSMARTLISTTYPE)
                VALUES (50, 4, 'NoCkid', 0, ?)
            """, arguments: [Self.customType])
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    // MARK: - create: --flagged round-trips to flagged filter bytes

    @Test func createFlagged() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created")

        var args = SmartListFilterArgs(); args.flagged = true
        let out = try await SmartListCreate.perform(
            name: "Flags Only", color: nil, symbol: nil, emoji: nil,
            filterArgs: args, json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created smart list: Flags Only\nFilter: Flagged reminders\n")
        // The mock recorded a createSmartList with filterData round-tripping to a flagged filter.
        #expect(mock.calls.count == 1)
        guard case let .createSmartList(name, filterData, appearance) = mock.calls[0] else {
            Issue.record("expected createSmartList call"); return
        }
        #expect(name == "Flags Only")
        #expect(appearance.isEmpty)
        // Compact, space-free bytes.
        #expect(String(data: filterData, encoding: .utf8) == #"{"flagged":true}"#)
        // And they decode back to a supported flagged summary.
        let decoded = decodeSmartListFilterBlob(filterData)
        let kind = decoded.summary?.first(where: { $0.0 == "kind" })?.1
        #expect(kind == .string("flagged"))
    }

    // MARK: - create: JSON output shape

    @Test func createFlaggedJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["objectUUID": .string("NEW-UUID")])

        var args = SmartListFilterArgs(); args.flagged = true
        let out = try await SmartListCreate.perform(
            name: "Flags Only", color: nil, symbol: nil, emoji: nil,
            filterArgs: args, json: true, store: s, private: mock)

        #expect(out.exitCode == 0)
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["status"] as? String == "created")
        #expect(obj["name"] as? String == "Flags Only")
        let filter = try #require(obj["filter"] as? [String: Any])
        #expect(filter["kind"] as? String == "flagged")
        #expect(filter["description"] as? String == "Flagged reminders")
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "created")
        #expect(priv["objectUUID"] as? String == "NEW-UUID")
    }

    // MARK: - create: duplicate name

    @Test func createDuplicateName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        var args = SmartListFilterArgs(); args.flagged = true
        let out = await WriteDispatch.perform {
            try await SmartListCreate.perform(
                name: "High Priority", color: nil, symbol: nil, emoji: nil,
                filterArgs: args, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: smart list already exists: High Priority. Choose a unique test name.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: unsupported/empty filter shape

    @Test func createEmptyFilterRejected() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        // No filter flags at all → build_supported_filter_payload raises "Pass at least one smart list filter."
        let args = SmartListFilterArgs()
        let out = await WriteDispatch.perform {
            try await SmartListCreate.perform(
                name: "Empty", color: nil, symbol: nil, emoji: nil,
                filterArgs: args, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Pass at least one smart list filter.\n")
        #expect(mock.calls.isEmpty)
    }

    @Test func createAllFilterJSONRejected() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        // An explicit empty filter object via --filter-json → summary kind "all" → encode rejects it.
        var args = SmartListFilterArgs(); args.filterJSON = "{}"
        let out = await WriteDispatch.perform {
            try await SmartListCreate.perform(
                name: "All", color: nil, symbol: nil, emoji: nil,
                filterArgs: args, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Unsupported smart list filter shape.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: materialization guard (--untagged)

    @Test func createUntaggedRejected() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        var args = SmartListFilterArgs(); args.untagged = true
        let out = await WriteDispatch.perform {
            try await SmartListCreate.perform(
                name: "Untagged", color: nil, symbol: nil, emoji: nil,
                filterArgs: args, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Untagged smart-list writes do not materialize reliably in Reminders.app.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: helper failure

    @Test func createHelperFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "boom")

        var args = SmartListFilterArgs(); args.flagged = true
        let out = await WriteDispatch.perform {
            try await SmartListCreate.perform(
                name: "Flags", color: nil, symbol: nil, emoji: nil,
                filterArgs: args, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Failed to create smart list 'Flags': boom\n")
    }

    // MARK: - create: appearance passes through

    @Test func createWithAppearance() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created")

        var args = SmartListFilterArgs(); args.flagged = true
        _ = try await SmartListCreate.perform(
            name: "Pretty", color: "blue", symbol: "default", emoji: nil,
            filterArgs: args, json: false, store: s, private: mock)

        guard case let .createSmartList(_, _, appearance) = mock.calls[0] else {
            Issue.record("expected createSmartList call"); return
        }
        #expect(appearance.color == "blue")
        #expect(appearance.symbol == "default")
    }

    // MARK: - edit: appearance-only change omits filterData (nil)

    @Test func editAppearanceOnly() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await SmartListEdit.perform(
            name: "High Priority", smartListId: nil,
            color: "red", symbol: nil, emoji: nil,
            filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        #expect(out.stdout == "Updated smart list: High Priority\n")
        #expect(mock.calls.count == 1)
        guard case let .updateSmartList(ckid, filterData, appearance) = mock.calls[0] else {
            Issue.record("expected updateSmartList call"); return
        }
        #expect(ckid == "SL30")
        #expect(filterData == nil)          // OMITTED — existing filter preserved
        #expect(appearance.color == "red")
    }

    // MARK: - edit: filter change sets filterData

    @Test func editFilterChange() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        var args = SmartListFilterArgs(); args.priority = "high"
        let out = try await SmartListEdit.perform(
            name: "High Priority", smartListId: nil,
            color: nil, symbol: nil, emoji: nil,
            filterArgs: args, json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        #expect(out.stdout == "Updated smart list: High Priority\nFilter: Priority: high\n")
        guard case let .updateSmartList(ckid, filterData, _) = mock.calls[0] else {
            Issue.record("expected updateSmartList call"); return
        }
        #expect(ckid == "SL30")
        #expect(String(data: try #require(filterData), encoding: .utf8) == #"{"priorities":["high"]}"#)
    }

    // MARK: - edit: filter-change JSON output includes filter

    @Test func editFilterChangeJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        var args = SmartListFilterArgs(); args.priority = "high"
        let out = try await SmartListEdit.perform(
            name: "High Priority", smartListId: nil,
            color: nil, symbol: nil, emoji: nil,
            filterArgs: args, json: true, store: s, private: mock)

        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["status"] as? String == "updated")
        #expect(obj["id"] as? Int == 30)
        #expect(obj["objectUUID"] as? String == "SL30")
        #expect(obj["name"] as? String == "High Priority")
        let filter = try #require(obj["filter"] as? [String: Any])
        #expect(filter["kind"] as? String == "priority")
        #expect(obj["private"] != nil)
    }

    // MARK: - edit: appearance-only JSON output omits filter

    @Test func editAppearanceOnlyJSONOmitsFilter() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await SmartListEdit.perform(
            name: "High Priority", smartListId: nil,
            color: "red", symbol: nil, emoji: nil,
            filterArgs: SmartListFilterArgs(), json: true, store: s, private: mock)

        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["filter"] == nil)   // no "filter" key when only appearance changed
        #expect(obj["status"] as? String == "updated")
    }

    // MARK: - edit: by --smart-list-id

    @Test func editBySmartListId() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await SmartListEdit.perform(
            name: nil, smartListId: 30,
            color: "green", symbol: nil, emoji: nil,
            filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)

        #expect(out.stdout == "Updated smart list: High Priority\n")
        guard case let .updateSmartList(ckid, _, _) = mock.calls[0] else {
            Issue.record("expected updateSmartList call"); return
        }
        #expect(ckid == "SL30")
    }

    // MARK: - edit: change-detection error

    @Test func editNoChanges() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: "High Priority", smartListId: nil,
                color: nil, symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass at least one smart-list filter or appearance option.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - edit: neither name nor id

    @Test func editNoTarget() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: nil, smartListId: nil,
                color: "red", symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: provide a smart list name or --smart-list-id.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - edit: not found by name / by id

    @Test func editNotFoundByName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: "Ghost", smartListId: nil,
                color: "red", symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: custom smart list not found: Ghost\n")
    }

    @Test func editNotFoundById() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: nil, smartListId: 999,
                color: "red", symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: custom smart list not found: id 999\n")
    }

    // MARK: - edit: ambiguous exact name

    @Test func editAmbiguous() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: "Dup", smartListId: nil,
                color: "red", symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: multiple custom smart lists match. Use --smart-list-id.\n  40: Dup\n  41: Dup\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - edit: no ckid

    @Test func editNoCkid() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: "NoCkid", smartListId: nil,
                color: "red", symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: target smart list has no stable CloudKit identifier.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - edit: helper failure

    @Test func editHelperFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "nope")

        let out = await WriteDispatch.perform {
            try await SmartListEdit.perform(
                name: "High Priority", smartListId: nil,
                color: "red", symbol: nil, emoji: nil,
                filterArgs: SmartListFilterArgs(), json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Failed to edit smart list 'High Priority': nope\n")
    }

    // MARK: - delete: confirm accepted

    @Test func deleteConfirmed() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "deleted")
        var prompted = ""

        let out = try await SmartListDelete.perform(
            name: "High Priority", smartListId: nil, force: false, json: false,
            store: s, private: mock, confirm: { prompt in prompted = prompt; return true })

        #expect(prompted == "Delete custom smart list 'High Priority'? [y/N] ")
        #expect(out.stdout == "Deleted smart list: High Priority\n")
        #expect(mock.calls == [.deleteSmartList(smartListId: "SL30")])
    }

    // MARK: - delete: confirm declined → Aborted (exit 0, no JSON even with --json)

    @Test func deleteAborted() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await SmartListDelete.perform(
            name: "High Priority", smartListId: nil, force: false, json: true,
            store: s, private: mock, confirm: { _ in false })

        #expect(out.exitCode == 0)
        #expect(out.stdout == "Aborted.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - delete: --force skips confirmation + JSON output

    @Test func deleteForceJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "deleted")
        var confirmCalled = false

        let out = try await SmartListDelete.perform(
            name: "High Priority", smartListId: nil, force: true, json: true,
            store: s, private: mock, confirm: { _ in confirmCalled = true; return true })

        #expect(confirmCalled == false)
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["status"] as? String == "deleted")
        #expect(obj["id"] as? Int == 30)
        #expect(obj["objectUUID"] as? String == "SL30")
        #expect(obj["name"] as? String == "High Priority")
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "deleted")
        #expect(mock.calls == [.deleteSmartList(smartListId: "SL30")])
    }

    // MARK: - delete: by --smart-list-id

    @Test func deleteBySmartListId() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "deleted")

        let out = try await SmartListDelete.perform(
            name: nil, smartListId: 30, force: true, json: false,
            store: s, private: mock, confirm: { _ in true })

        #expect(out.stdout == "Deleted smart list: High Priority\n")
        #expect(mock.calls == [.deleteSmartList(smartListId: "SL30")])
    }

    // MARK: - delete: not found

    @Test func deleteNotFound() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListDelete.perform(
                name: "Ghost", smartListId: nil, force: true, json: false,
                store: s, private: mock, confirm: { _ in true })
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: custom smart list not found: Ghost\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - delete: ambiguous

    @Test func deleteAmbiguous() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = await WriteDispatch.perform {
            try await SmartListDelete.perform(
                name: "Dup", smartListId: nil, force: true, json: false,
                store: s, private: mock, confirm: { _ in true })
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: multiple custom smart lists match. Use --smart-list-id.\n  40: Dup\n  41: Dup\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - delete: helper failure

    @Test func deleteHelperFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "denied")

        let out = await WriteDispatch.perform {
            try await SmartListDelete.perform(
                name: "High Priority", smartListId: nil, force: true, json: false,
                store: s, private: mock, confirm: { _ in true })
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Failed to delete smart list 'High Priority': denied\n")
    }
}
