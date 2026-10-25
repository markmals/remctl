import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// Reminders list groups (upstream e013fb9): `groups`/`group-info` reads, and the group writes,
/// each read back from the store before it is reported.
@Suite struct GroupCommandTests {
    /// Group 'Writing' (id 1, CK-1) holds Reviews (id 3) then Editorial (id 2); Work (id 4) is
    /// ungrouped. Editorial has one active and one completed reminder.
    private func fixture() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP) VALUES (1,3,'Writing','CK-1',0,1);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZPARENTLIST,Z_FOK_PARENTLIST) VALUES (2,3,'Editorial','CK-2',0,1,2048);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZPARENTLIST1,Z_FOK_PARENTLIST1) VALUES (3,3,'Reviews','CK-3',0,1,3072);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (4,3,'Work','CK-4',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,'Draft',2,1,0,0,'R10');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (11,'Shipped',2,1,1,0,'R11');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (12,'Review',3,1,0,0,'R12');
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A private writer that applies each write to the fixture the way Reminders does: a list
    /// added to a group lands at the top of it. `applying` decides which writes actually land.
    private func reminders(_ dir: URL, applying: @escaping (MockPrivateWriter.Call) -> Bool = { _ in true }) -> MockPrivateWriter {
        let p = MockPrivateWriter()
        let path = dir.appendingPathComponent("Data-test.sqlite").path
        p.reply = { call in
            switch call {
            case .createGroup: PrivateResult(status: "created", fields: ["id": .string("NEW-G")])
            case .createList: PrivateResult(status: "created", fields: ["id": .string("NEW-L")])
            case .deleteGroup: PrivateResult(status: "deleted")
            default: PrivateResult(status: "updated")
            }
        }
        p.onCall = { call in
            guard applying(call), let sql = Self.sql(for: call) else { return }
            let queue = try? DatabaseQueue(path: path)
            try? queue?.write { try $0.execute(sql: sql.0, arguments: StatementArguments(sql.1)) }
        }
        return p
    }

    private static func sql(for call: MockPrivateWriter.Call) -> (String, [DatabaseValueConvertible?])? {
        switch call {
        case .createGroup(let name):
            return ("INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP) VALUES (100,3,?,'NEW-G',0,1)", [name])
        case .createList(let name, _):
            return ("INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (101,3,?,'NEW-L',0)", [name])
        case .setListParentGroup(let listId, let groupId?):
            return ("""
                UPDATE ZREMCDBASELIST SET ZPARENTLIST = (SELECT Z_PK FROM ZREMCDBASELIST WHERE ZCKIDENTIFIER = ?),
                  ZPARENTLIST1 = NULL, Z_FOK_PARENTLIST1 = NULL,
                  Z_FOK_PARENTLIST = (SELECT MAX(MAX(COALESCE(Z_FOK_PARENTLIST, 0)), MAX(COALESCE(Z_FOK_PARENTLIST1, 0))) + 1024 FROM ZREMCDBASELIST)
                WHERE ZCKIDENTIFIER = ?
                """, [groupId, listId])
        case .setListParentGroup(let listId, nil):
            return ("UPDATE ZREMCDBASELIST SET ZPARENTLIST = NULL, ZPARENTLIST1 = NULL, Z_FOK_PARENTLIST = NULL, Z_FOK_PARENTLIST1 = NULL WHERE ZCKIDENTIFIER = ?", [listId])
        case .setListAppearance(let listId, let appearance):
            return ("UPDATE ZREMCDBASELIST SET ZNAME = ? WHERE ZCKIDENTIFIER = ?", [appearance.name, listId])
        case .deleteGroup(let groupId):
            return ("UPDATE ZREMCDBASELIST SET ZMARKEDFORDELETION = 1 WHERE ZCKIDENTIFIER = ?", [groupId])
        default:
            return nil
        }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func titles(_ value: Any?) -> [String] {
        (value as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
    }

    // MARK: - groups / group-info

    @Test func groupsJSONListsOnlyGroupsWithChildCounts() throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["groups", "--json"], storeDir: dir)
        let groups = try #require(JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]])
        #expect(groups.map { $0["title"] as? String } == ["Writing"])
        #expect(groups[0]["counts"] as? [String: Int] == ["active": 2, "completed": 1, "total": 3])
        #expect(titles(groups[0]["children"]) == ["Reviews", "Editorial"])
    }

    @Test func groupsTableShowsCountsPerList() throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["groups", "--format", "table"], storeDir: dir)
        #expect(r.stdout.contains("│ ID │ Title       │ Group   │ Active │ Done │ Total │"))
        #expect(r.stdout.contains("│ 2  │   Editorial │ Writing │ 1      │ 1    │ 2     │"))
    }

    @Test func groupInfoReportsChildrenCountsAndFollowUpCommands() throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["group-info", "writing", "--json"], storeDir: dir)
        let payload = try json(r.stdout)
        #expect(payload["method"] as? String == "case_insensitive")
        #expect(payload["counts"] as? [String: Int] == ["active": 2, "completed": 1, "total": 3])
        #expect(titles(payload["children"]) == ["Reviews", "Editorial"])
        let commands = try #require(payload["suggestedCommands"] as? [String: String])
        #expect(commands["createList"] == "remctl list-create LIST --group Writing")
    }

    @Test func groupInfoRefusesAnOrdinaryList() throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["group-info", "--group-id", "4"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr == "Error: 'Work' is a list, not a Reminders list group.\n")
    }

    // MARK: - group-create

    @Test func groupCreateMovesListsInOnceTheGroupIsVisible() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        let out = try await GroupCreate.perform(name: "New Group", addLists: ["Editorial"], addListIds: [4], json: true,
                                                store: store, private: p, readback: .immediate)
        #expect(p.calls == [
            .createGroup(name: "New Group"),
            .setListParentGroup(listId: "CK-4", groupId: "NEW-G"),
            .setListParentGroup(listId: "CK-2", groupId: "NEW-G"),
        ])
        let payload = try json(out.stdout)
        #expect(payload["id"] as? Int == 100)
        #expect(payload["verified"] as? Bool == true)
        #expect(titles(payload["addedLists"]) == ["Work", "Editorial"])
        #expect(store.listIsLive(2, inGroup: 100))
    }

    @Test func groupCreateRefusesATakenName() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        let out = await WriteDispatch.perform(json: true) {
            try await GroupCreate.perform(name: "Work", addLists: [], addListIds: [], json: true,
                                          store: store, private: p, readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "group_exists")
        #expect(p.calls.isEmpty)
    }

    @Test func groupCreateMovesNoListWhenTheGroupNeverAppears() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir) { _ in false }
        let out = await WriteDispatch.perform(json: true) {
            try await GroupCreate.perform(name: "New Group", addLists: ["Work"], addListIds: [], json: true,
                                          store: store, private: p, readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "group_write_unverified")
        #expect(p.calls == [.createGroup(name: "New Group")])
    }

    // MARK: - group-edit

    @Test func groupEditRenamesThenAddsAndRemovesLists() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        var request = GroupEditRequest(newName: "Drafts")
        request.addLists = ["Work"]; request.removeLists = ["Editorial"]
        let out = try await GroupEdit.perform(name: "Writing", groupId: nil, request: request, json: true,
                                              store: store, private: p, readback: .immediate)
        #expect(p.calls == [
            .setListAppearance(listId: "CK-1", appearance: ListAppearance(name: "Drafts")),
            .setListParentGroup(listId: "CK-4", groupId: "CK-1"),
            .setListParentGroup(listId: "CK-2", groupId: nil),
        ])
        let payload = try json(out.stdout)
        let renamed = try #require(payload["renamed"] as? [String: Any])
        #expect(renamed["oldName"] as? String == "Writing")
        #expect(renamed["newName"] as? String == "Drafts")
        #expect(titles(payload["addedLists"]) == ["Work"])
        #expect(titles(payload["removedLists"]) == ["Editorial"])
    }

    @Test func groupEditPlacesAListBeforeASiblingByReattachingInReverse() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        var request = GroupEditRequest(); request.moveList = "Work"; request.beforeList = "Editorial"
        let out = try await GroupEdit.perform(name: "Writing", groupId: nil, request: request, json: true,
                                              store: store, private: p, readback: .immediate)
        #expect(p.calls == [
            .setListParentGroup(listId: "CK-3", groupId: nil),
            .setListParentGroup(listId: "CK-2", groupId: nil),
            .setListParentGroup(listId: "CK-2", groupId: "CK-1"),
            .setListParentGroup(listId: "CK-4", groupId: "CK-1"),
            .setListParentGroup(listId: "CK-3", groupId: "CK-1"),
        ])
        #expect(store.childLists(groupPk: 1).map { $0.string("ZNAME") } == ["Reviews", "Work", "Editorial"])
        let moved = try #require(try json(out.stdout)["movedList"] as? [String: Any])
        #expect(moved["position"] as? String == "before")
        #expect((moved["relativeTo"] as? [String: Any])?["title"] as? String == "Editorial")
        #expect((moved["private"] as? [String: Any])?["method"] as? String == "detach_reattach")
    }

    @Test func groupEditMovesAChildLastAfterTheCurrentLastSibling() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        var request = GroupEditRequest(); request.moveList = "Reviews"; request.last = true
        let out = try await GroupEdit.perform(name: nil, groupId: 1, request: request, json: false,
                                              store: store, private: p, readback: .immediate)
        #expect(store.childLists(groupPk: 1).map { $0.string("ZNAME") } == ["Editorial", "Reviews"])
        #expect(out.stdout == "Updated group: Writing\nMoved list: Reviews after Editorial\n")
    }

    @Test func groupEditValidatesEveryEditBeforeTheFirstWrite() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        var request = GroupEditRequest(newName: "Drafts"); request.removeLists = ["Work"]
        let out = await WriteDispatch.perform(json: false) {
            try await GroupEdit.perform(name: "Writing", groupId: nil, request: request, json: false,
                                        store: store, private: p, readback: .immediate)
        }
        #expect(out.stderr == "Error: list 'Work' is not currently in group 'Writing'.\n")
        #expect(p.calls.isEmpty)
    }

    @Test func groupEditNamesTheListsAReorderLeftAtTheTopLevel() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir) { $0 != .setListParentGroup(listId: "CK-2", groupId: "CK-1") }
        var request = GroupEditRequest(); request.moveList = "Work"; request.beforeList = "Editorial"
        let out = await WriteDispatch.perform(json: true) {
            try await GroupEdit.perform(name: "Writing", groupId: nil, request: request, json: true,
                                        store: store, private: p, readback: .immediate)
        }
        let payload = try json(out.stderr)
        #expect(payload["code"] as? String == "group_write_unverified")
        #expect((payload["message"] as? String)?.hasSuffix("These lists are now at the top level: 'Reviews', 'Editorial'.") == true)
        #expect(titles(payload["listsAtTopLevel"]) == ["Reviews", "Editorial"])
    }

    @Test func groupEditTakesOnePosition() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var request = GroupEditRequest(); request.moveList = "Work"; request.first = true; request.last = true
        let out = await WriteDispatch.perform(json: true) {
            try await GroupEdit.perform(name: "Writing", groupId: nil, request: request, json: true,
                                        store: store, private: MockPrivateWriter(), readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "invalid_group_edit")
    }

    // MARK: - group-delete

    @Test func groupDeleteDetachesEveryChildBeforeDeletingTheGroup() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        let out = try await GroupDelete.perform(name: "Writing", groupId: nil, force: true, json: true,
                                                store: store, private: p, confirm: .unexpected, readback: .immediate)
        #expect(p.calls == [
            .setListParentGroup(listId: "CK-3", groupId: nil),
            .setListParentGroup(listId: "CK-2", groupId: nil),
            .deleteGroup(groupId: "CK-1"),
        ])
        #expect(titles(try json(out.stdout)["detachedLists"]) == ["Reviews", "Editorial"])
        #expect(store.listIsLive(2, inGroup: nil))
        #expect(store.reminders(listPk: 2, completed: true).count == 2)
    }

    @Test func groupDeleteKeepsTheGroupWhenAChildDoesNotLeave() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir) { $0 != .setListParentGroup(listId: "CK-2", groupId: nil) }
        let out = await WriteDispatch.perform(json: true) {
            try await GroupDelete.perform(name: "Writing", groupId: nil, force: true, json: true,
                                          store: store, private: p, confirm: .unexpected, readback: .immediate)
        }
        #expect(out.exitCode == 1)
        #expect(!p.calls.contains(.deleteGroup(groupId: "CK-1")))
    }

    @Test func groupDeleteNeedsForceUnderJSON() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        let out = try await GroupDelete.perform(name: "Writing", groupId: nil, force: false, json: true,
                                                store: store, private: p, confirm: .unexpected, readback: .immediate)
        let payload = try json(out.stderr)
        #expect(payload["code"] as? String == "confirmation_required")
        #expect(payload["id"] as? Int == 1)
        #expect(p.calls.isEmpty)
    }

    // MARK: - list-create --group

    @Test func listCreateInAGroupMovesTheNewListIn() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        let out = try await ListCreate.performInGroup(
            name: "Research", group: "Writing", groupId: nil, color: nil, symbol: nil, emoji: nil,
            groceries: false, groceryLocale: nil, json: true, store: store, private: p, readback: .immediate)
        #expect(p.calls == [
            .createList(name: "Research", appearance: ListAppearance()),
            .setListParentGroup(listId: "NEW-L", groupId: "CK-1"),
        ])
        let payload = try json(out.stdout)
        #expect(payload["id"] as? Int == 101)
        #expect((payload["group"] as? [String: Any])?["title"] as? String == "Writing")
        #expect((payload["membership"] as? [String: Any])?["status"] as? String == "updated")
    }

    @Test func listCreateRefusesAListAsItsGroupBeforeWriting() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir)
        let out = await WriteDispatch.perform(json: true) {
            try await ListCreate.performInGroup(
                name: "Research", group: nil, groupId: 4, color: nil, symbol: nil, emoji: nil,
                groceries: false, groceryLocale: nil, json: true, store: store, private: p, readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "not_a_group")
        #expect(p.calls.isEmpty)
    }
}
