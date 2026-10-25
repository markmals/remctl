import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `deleted`, `restore`, and `info --include-deleted` (upstream a413c19, 42e6b24, c831b05,
/// 972487f): Apple's recovery view decides what is recoverable, paging keeps subtasks with their
/// parent, and a recovery is reported only once the store shows the original ids and hierarchy.
@Suite struct RecentlyDeletedTests {

    // MARK: - Fixtures

    private func identifier(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    /// One entry of the recovery view as ReminderKit reports it.
    private func native(_ n: Int, _ children: [JSONValue] = []) -> JSONValue {
        .object([("objectID", .object([("uuid", .string(identifier(n)))])), ("subtasks", .array(children))])
    }

    private func view(_ items: [JSONValue]) -> PrivateResult {
        PrivateResult(status: "ok", fields: ["reminders": .array(items)])
    }

    /// 'Recovered' (pk 10, CK-L) and 'Elsewhere' (pk 11, CK-E) are live lists; reminders 1-4 are
    /// tombstones with their lists cleared, and #2 is #1's subtask. The recovery view below names
    /// only 1 (with 2) and 3, so #4 stands in for a purged row the deleted flag still matches.
    private func fixture() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER) VALUES (10,3,'Recovered','CK-L');
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER) VALUES (11,3,'Elsewhere','CK-E');
                """)
            for n in 1...4 {
                try db.execute(sql: """
                    INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZNOTES,ZCKIDENTIFIER,ZPARENTREMINDER,ZACCOUNT,ZMARKEDFORDELETION)
                    VALUES (?,?,'body',?,?,1,1)
                    """, arguments: [n, "Reminder \(n)", identifier(n), n == 2 ? 1 : nil])
            }
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Applies fixture SQL through a writable connection — the store under test is read-only.
    /// Sync on purpose: GRDB's async `write` overload would win inside an async test.
    private func mutate(_ dir: URL, _ statements: String...) {
        guard let queue = try? DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path) else { return }
        try? queue.write { db in for sql in statements { try db.execute(sql: sql) } }
    }

    /// The default recovery view: #1 with subtask #2, and #3.
    private func writer(_ items: [JSONValue]? = nil) -> MockPrivateWriter {
        let mock = MockPrivateWriter()
        mock.recentlyDeletedResult = view(items ?? [native(1, [native(2)]), native(3)])
        return mock
    }

    private func restore(_ id: Int, list: String? = nil, listId: Int? = 10, store: RemindersStore,
                         private mock: MockPrivateWriter) async -> WriteOutcome {
        await WriteDispatch.perform(json: true) {
            try await Restore.perform(id: id, list: list, listId: listId, json: true,
                                      store: store, private: mock, readback: .immediate)
        }
    }

    /// Reads the recovery view through the command error convention, so a refusal is observable.
    private func read(store: RemindersStore, private mock: MockPrivateWriter, json: Bool = true) async -> WriteOutcome {
        await WriteDispatch.perform(json: json) {
            _ = try await RecentlyDeleted.read(store: store, private: mock)
            return .ok("")
        }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func errorCode(_ outcome: WriteOutcome) throws -> String {
        #expect(outcome.exitCode == 1)
        #expect(outcome.stdout.isEmpty)
        return try #require(json(outcome.stderr)["code"] as? String)
    }

    private func restoreCalls(_ mock: MockPrivateWriter) -> Int {
        mock.calls.filter { if case .restoreReminder = $0 { return true } else { return false } }.count
    }

    // MARK: - Membership and decoration

    @Test func recoveryViewDecidesMembershipAndCarriesNumericIds() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = try await RecentlyDeleted.read(store: store, private: writer())

        #expect(items.map(\.id) == [1, 3])
        #expect(items[0].subtasks.map(\.id) == [2])
        #expect(items[0].subtasks[0].restoreId == 1)
        #expect(items[0].restoreId == 1)
        #expect(items[0].identifier == identifier(1))
        // A tombstone the view does not name (#4) is NOT recoverable.
        #expect(RecentlyDeleted.find(items, id: 4) == nil)
        // Deleted reminders stay out of every regular read.
        #expect(store.reminder(pk: 1) == nil)

        let payload = try json(JSONValue.object(items[0].payload).serialized(indent: nil, ensureAscii: true))
        #expect(payload["deleted"] as? Bool == true)
        #expect(payload["recoverable"] as? Bool == true)
        #expect(payload["restoreId"] as? Int == 1)
        #expect(payload["notes"] as? String == "body")
        #expect(payload["subtaskCount"] as? Int == 1)
        // Deletion clears the original list, so there is nothing to report.
        #expect(payload["list"] is NSNull)
        #expect((payload["subtasks"] as? [[String: Any]])?.first?["id"] as? Int == 2)
    }

    @Test func storeDecorationSkipsLiveRowsAndRowsWithoutAnAccount() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        mutate(dir, "UPDATE ZREMCDREMINDER SET ZMARKEDFORDELETION = 0 WHERE Z_PK = 1",
               "UPDATE ZREMCDREMINDER SET ZACCOUNT = NULL WHERE Z_PK = 2")
        let rows = store.deletedReminders(identifiers: (1...4).map { identifier($0) })
        #expect(Set(rows.keys) == Set([3, 4].map { identifier($0).lowercased() }))
        #expect(rows[identifier(3).lowercased()]?.int("Z_PK") == 3)
    }

    @Test func storeDecorationBatchesLongRecoveryLists() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // More identifiers than one batch carries, with the real rows in the LAST batch.
        let padding = (100..<(100 + RemindersStore.deletedReminderBatch)).map { identifier($0) }
        let rows = store.deletedReminders(identifiers: padding + (1...4).map { identifier($0).uppercased() })
        #expect(rows.count == 4)
        #expect(rows[identifier(2).lowercased()]?.int("ZPARENTREMINDER") == 1)
    }

    // MARK: - Paging

    @Test func pagingCountsParentsAndKeepsChildrenWithThem() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = try await RecentlyDeleted.read(store: store, private: writer())

        let first = try json(Deleted.render(items, limit: 1, offset: 0, json: true).stdout)
        #expect(first["total"] as? Int == 2)
        #expect(first["count"] as? Int == 1)
        #expect(first["offset"] as? Int == 0)
        #expect(first["limit"] as? Int == 1)
        #expect(first["hasMore"] as? Bool == true)
        #expect(first["nextOffset"] as? Int == 1)
        let parents = try #require(first["items"] as? [[String: Any]])
        #expect((parents[0]["subtasks"] as? [[String: Any]])?.first?["id"] as? Int == 2)

        let last = try json(Deleted.render(items, limit: 1, offset: 1, json: true).stdout)
        #expect(last["hasMore"] as? Bool == false)
        #expect(last["nextOffset"] is NSNull)
        #expect((last["items"] as? [[String: Any]])?.count == 1)

        let past = try json(Deleted.render(items, limit: 100, offset: 9, json: true).stdout)
        #expect(past["count"] as? Int == 0)
        #expect(past["total"] as? Int == 2)
        #expect(past["nextOffset"] is NSNull)
    }

    @Test func humanPagingNamesTheNextPageAndTheEmptyCase() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let items = try await RecentlyDeleted.read(store: store, private: writer())
        let page = Deleted.render(items, limit: 1, offset: 0, json: false).stdout
        #expect(page == "  #1 Reminder 1 (1 subtasks)\nMore results: remctl deleted --offset 1 --limit 1\n")
        #expect(Deleted.render([], limit: 100, offset: 0, json: false).stdout == "No recently deleted reminders\n")
    }

    @Test func pageBoundsAreRejectedBeforeAnyRead() async throws {
        for (limit, offset, expected) in [(0, nil, "invalid_limit"), (501, nil, "invalid_limit"),
                                          (nil, -1, "invalid_offset")] as [(Int?, Int?, String)] {
            let outcome = await WriteDispatch.perform(json: true) {
                let page = try recoveryPageArgs(limit: limit, offset: offset)
                return .ok("\(page.limit) \(page.offset)")
            }
            let code = try errorCode(outcome)
            #expect(code == expected)
        }
        let bounds = try recoveryPageArgs(limit: nil, offset: nil)
        #expect(bounds.limit == RemindersStore.searchDefaultLimit)
        #expect(bounds.offset == 0)
    }

    // MARK: - Fail-closed reads

    @Test func unavailableMalformedAndChangedResultsFailClosed() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, PrivateResult, String)] = [
            ("helper error", PrivateResult(status: "error", message: "unavailable"), "recently_deleted_unavailable"),
            ("no reminders key", PrivateResult(status: "ok", fields: [:]), "recently_deleted_unavailable"),
            ("empty entry", view([.object([])]), "recently_deleted_unavailable"),
            ("bad uuid", view([.object([("objectID", .object([("uuid", .string("bad"))]))])]),
             "recently_deleted_unavailable"),
            ("bad uuid after a good one",
             view([native(1, [native(2)]), .object([("objectID", .object([("uuid", .string("bad"))]))])]),
             "recently_deleted_unavailable"),
            ("subtasks is not a list",
             view([.object([("objectID", .object([("uuid", .string(identifier(1)))])), ("subtasks", .int(3))])]),
             "recently_deleted_unavailable"),
            ("row gone since the read", view([native(99)]), "recently_deleted_changed"),
        ]
        for (label, result, expected) in cases {
            let mock = MockPrivateWriter()
            mock.recentlyDeletedResult = result
            let code = try errorCode(await read(store: store, private: mock))
            #expect(code == expected, "\(label)")
        }
    }

    @Test func recoveryErrorsFollowTheOutputMode() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.recentlyDeletedResult = PrivateResult(status: "error",
                                                   message: "No account supports Recently Deleted on this Mac")
        let plain = await read(store: store, private: mock, json: false)
        #expect(plain.exitCode == 1)
        #expect(plain.stderr == "Error: No account supports Recently Deleted on this Mac\n")

        let code = try errorCode(await restore(1, store: store, private: mock))
        #expect(code == "recently_deleted_unavailable")
    }

    @Test func deepHierarchiesAreRefusedRatherThanRecursedForever() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var node = native(1)
        for _ in 0...RecentlyDeleted.maxDepth { node = native(1, [node]) }
        let mock = MockPrivateWriter()
        mock.recentlyDeletedResult = view([node])
        let code = try errorCode(await read(store: store, private: mock))
        #expect(code == "recently_deleted_unavailable")
    }

    // MARK: - info --include-deleted

    @Test func infoCanInspectADeletedSubtaskAndNeedsTheOptIn() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try #require(await Info.deletedDetails(id: 2, json: true, store: store, private: writer()))
        #expect(outcome.exitCode == 0)
        let payload = try json(outcome.stdout)
        #expect(payload["id"] as? Int == 2)
        #expect(payload["restoreId"] as? Int == 1)
        #expect(payload["deleted"] as? Bool == true)

        let human = try #require(await Info.deletedDetails(id: 2, json: false, store: store, private: writer()))
        #expect(human.stdout == "Recently deleted: #2 Reminder 2\nRestore with: remctl restore 1 --list LIST\n")

        // An id the view does not name falls through to the regular "#N not found" read.
        let unnamed = await Info.deletedDetails(id: 4, json: true, store: store, private: writer())
        #expect(unnamed == nil)
        // The opt-in is off by default, so `info` never asks ReminderKit.
        #expect(try Info.parse(["2", "--json"]).includeDeleted == false)
        #expect(try Info.parse(["2", "--include-deleted"]).includeDeleted == true)
    }

    @Test func infoKeepsRecoveryFailuresStructured() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.recentlyDeletedResult = PrivateResult(status: "error", message: "unavailable")
        let outcome = try #require(await Info.deletedDetails(id: 2, json: true, store: store, private: mock))
        let code = try errorCode(outcome)
        #expect(code == "recently_deleted_unavailable")

        // A live reminder never reaches the recovery view at all.
        mutate(dir, "UPDATE ZREMCDREMINDER SET ZMARKEDFORDELETION=0,ZLIST=10 WHERE Z_PK=2")
        let live = try RemindersStore.open(storeDir: dir)
        let skipped = await Info.deletedDetails(id: 2, json: true, store: live, private: mock)
        #expect(skipped == nil)
        #expect(mock.calls.count == 1)
    }

    // MARK: - restore

    /// Reminders' save, as `restore` must see it: the tree becomes live in `listPk`, children
    /// keeping their parent. `flatten`/`rename` simulate a save that lost part of the identity.
    private func applyRestore(_ dir: URL, pks: [Int], listPk: Int = 10,
                              flatten: Bool = false, rename: Bool = false) -> (MockPrivateWriter.Call) -> Void {
        { call in
            guard case .restoreReminder = call else { return }
            let ids = pks.map(String.init).joined(separator: ",")
            self.mutate(dir, "UPDATE ZREMCDREMINDER SET ZMARKEDFORDELETION=0, ZLIST=\(listPk) WHERE Z_PK IN (\(ids))")
            if flatten {
                self.mutate(dir, "UPDATE ZREMCDREMINDER SET ZPARENTREMINDER=NULL WHERE Z_PK IN (\(ids))")
            }
            if rename {
                self.mutate(dir, "UPDATE ZREMCDREMINDER SET ZCKIDENTIFIER='wrong' WHERE Z_PK IN (\(ids))")
            }
        }
    }

    @Test func restoreMarshalsIdentifiersAndVerifiesTheWholeTree() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = writer()
        mock.onCall = applyRestore(dir, pks: [1, 2])

        let outcome = await restore(1, store: store, private: mock)
        #expect(outcome.exitCode == 0)
        let payload = try json(outcome.stdout)
        #expect(payload["status"] as? String == "restored")
        #expect(payload["id"] as? Int == 1)
        #expect(payload["title"] as? String == "Reminder 1")
        #expect(payload["list"] as? String == "Recovered")
        #expect(payload["verified"] as? Bool == true)
        // The reminder's own identifier and the DESTINATION list's identifier cross the boundary.
        #expect(mock.calls == [.recentlyDeleted, .restoreReminder(id: identifier(1), listId: "CK-L")])
    }

    @Test func restoreReportsTheRecoveryInHumanOutput() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = writer()
        mock.onCall = applyRestore(dir, pks: [1, 2])
        let outcome = await WriteDispatch.perform(json: false) {
            try await Restore.perform(id: 1, list: nil, listId: 10, json: false,
                                      store: store, private: mock, readback: .immediate)
        }
        #expect(outcome.stdout == "Restored: #1 in Recovered\n")
    }

    @Test func restoreVerifiesTheTreeEvenAfterAHelperErrorWithoutRetrying() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = writer()
        mock.result = PrivateResult(status: "error", message: "connection closed")
        mock.onCall = applyRestore(dir, pks: [1, 2])

        let outcome = await restore(1, store: store, private: mock)
        let payload = try json(outcome.stdout)
        #expect(payload["verified"] as? Bool == true)
        #expect(restoreCalls(mock) == 1)
    }

    @Test func partialRestoreOrWrongIdentityNeverClaimsSuccess() async throws {
        let variants: [(String, (URL) -> (MockPrivateWriter.Call) -> Void)] = [
            ("parent only", { self.applyRestore($0, pks: [1]) }),
            ("hierarchy lost", { self.applyRestore($0, pks: [1, 2], flatten: true) }),
            ("identity lost", { self.applyRestore($0, pks: [1, 2], rename: true) }),
            ("wrong list", { self.applyRestore($0, pks: [1, 2], listPk: 11) }),
        ]
        for (label, build) in variants {
            let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let mock = writer()
            mock.onCall = build(dir)
            let outcome = await restore(1, store: store, private: mock)
            let code = try errorCode(outcome)
            #expect(code == "restore_unconfirmed", "\(label)")
            let message = try json(outcome.stderr)["message"] as? String
            #expect(message == "Could not verify recovery of the reminder and all its subtasks. "
                    + "Check info and deleted before retrying.", "\(label)")
        }
    }

    @Test func activeRestoreIsANoopAndNeverMovesAnActiveReminder() async throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        mutate(dir, "UPDATE ZREMCDREMINDER SET ZMARKEDFORDELETION=0,ZLIST=10 WHERE Z_PK=1")
        let live = try RemindersStore.open(storeDir: dir)
        let mock = writer()

        let noop = await restore(1, store: live, private: mock)
        let payload = try json(noop.stdout)
        #expect(payload["status"] as? String == "already_restored")
        #expect(payload["list"] as? String == "Recovered")
        // #2 is still deleted, so the no-op must not claim the tree was verified.
        #expect(payload["verified"] == nil)
        #expect(payload["title"] == nil)
        #expect(mock.calls.isEmpty)

        let elsewhere = await restore(1, listId: 11, store: live, private: mock)
        let code = try errorCode(elsewhere)
        #expect(code == "reminder_not_deleted")
        #expect(mock.calls.isEmpty)
    }

    @Test func unknownAndChildRestoreDoNotWrite() async throws {
        for (id, expected) in [(4, "reminder_not_recoverable"), (2, "restore_parent_required")] {
            let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let mock = writer()
            let outcome = await restore(id, store: store, private: mock)
            let code = try errorCode(outcome)
            #expect(code == expected)
            #expect(mock.calls == [.recentlyDeleted])
        }
    }

    @Test func restoreDestinationErrorsAreStructuredAndWriteNothing() async throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        mutate(dir,
               "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZISGROUP) VALUES (12,3,'Group','CK-G',1)",
               "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER) VALUES (13,3,'Twin','CK-T1')",
               "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER) VALUES (14,3,'Twin','CK-T2')")
        let store = try RemindersStore.open(storeDir: dir)
        let cases: [(String?, Int?, String)] = [
            (nil, nil, "invalid_list_target"), ("Recovered", 10, "invalid_list_target"),
            ("Missing", nil, "list_not_found"), (nil, 99, "list_not_found"),
            ("Twin", nil, "list_ambiguous"), ("Group", nil, "list_is_group"),
        ]
        for (name, listId, expected) in cases {
            let mock = writer()
            let outcome = await restore(1, list: name, listId: listId, store: store, private: mock)
            let code = try errorCode(outcome)
            #expect(code == expected, "\(name ?? "nil")/\(listId.map(String.init) ?? "nil")")
            #expect(mock.calls.isEmpty)
        }
    }

    @Test func restoreRefusesADestinationWithoutAStableIdentifier() async throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        mutate(dir, "UPDATE ZREMCDBASELIST SET ZCKIDENTIFIER = '' WHERE Z_PK = 10")
        let store = try RemindersStore.open(storeDir: dir)
        let mock = writer()
        let outcome = await restore(1, store: store, private: mock)
        let code = try errorCode(outcome)
        #expect(code == "restore_missing_list_identifier")
        #expect(mock.calls == [.recentlyDeleted])
    }
}
