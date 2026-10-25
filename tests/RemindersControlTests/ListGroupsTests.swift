import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// Reminders list groups (ZISGROUP) hold lists, not reminders. They must never read back as
/// ordinary lists: `lists` nests them, `stats` leaves them out of the list count, a reminder
/// target refuses them, and `show <group>` reads through to the child lists.
@Suite struct ListGroupsTests {
    /// Group 'Writing' (id 1) with children 'Reviews' (id 3, via ZPARENTLIST1) and 'Editorial'
    /// (id 2, via ZPARENTLIST), plus the ungrouped list 'Work' (id 4). Editorial carries a manual
    /// display order that reverses its two active reminders. The group row also carries grocery
    /// flags, which a group must never report.
    private func groupStore() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP,ZSHOULDCATEGORIZEGROCERYITEMS)
              VALUES (1,3,'Writing','CK-1',0,1,1);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZPARENTLIST,Z_FOK_PARENTLIST,ZREMINDERIDSMERGEABLEORDERING_V2_JSON)
              VALUES (2,3,'Editorial','CK-2',0,1,2048,'["REM-11","REM-10"]');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZPARENTLIST1,Z_FOK_PARENTLIST1)
              VALUES (3,3,'Reviews','CK-3',0,1,3072);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION)
              VALUES (4,3,'Work','CK-4',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
              VALUES (10,'Editorial A',2,1,0,0,'REM-10');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
              VALUES (11,'Editorial B',2,1,0,0,'REM-11');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
              VALUES (12,'Editorial Done',2,1,1,0,'REM-12');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
              VALUES (13,'Review One',3,1,0,0,'REM-13');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
              VALUES (14,'Work Item',4,1,0,0,'REM-14');
            """)
        }
    }

    /// A group with no child lists, to cover the empty-group reads.
    private func emptyGroupStore() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP) VALUES (1,3,'Writing','CK-1',0,1)")
        }
    }

    // MARK: - lists

    @Test func listsJSONNestsChildrenUnderTheGroup() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let group = arr?.first { $0["title"] as? String == "Writing" }
        #expect(group?["listType"] as? String == "group")
        #expect(group?["isGroup"] as? Bool == true)
        #expect(group?["isGroceries"] as? Bool == false)   // a group is never a Groceries list
        #expect(group?["grocery"] == nil)
        // Reminders orders children by its sparse position keys, highest first.
        let children = group?["children"] as? [[String: Any]]
        #expect(children?.map { $0["title"] as? String } ?? [] == ["Reviews", "Editorial"])
        let counts = group?["counts"] as? [String: Any]
        #expect(counts?["active"] as? Int == 3)
        #expect(counts?["completed"] as? Int == 1)
        #expect(counts?["total"] as? Int == 4)
        let editorial = children?.first { $0["title"] as? String == "Editorial" }
        #expect(editorial?["parentListId"] as? Int == 1)
        #expect((editorial?["group"] as? [String: Any])?["title"] as? String == "Writing")
        #expect((editorial?["counts"] as? [String: Any])?["total"] as? Int == 3)
        // ZPARENTLIST1 names the same group as ZPARENTLIST does.
        let reviews = children?.first { $0["title"] as? String == "Reviews" }
        #expect(reviews?["parentListId"] as? Int == 1)
        // Children also stand on their own at the top level; an ungrouped list has no group.
        let work = arr?.first { $0["title"] as? String == "Work" }
        #expect(work?["group"] == nil)
        #expect(work?["isGroup"] as? Bool == false)
        #expect(arr?.map { $0["title"] as? String } ?? [] == ["Writing", "Reviews", "Editorial", "Work"])
    }

    @Test func listsHumanIndentsChildLists() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("  Writing (id: 1) [2 lists]\n"))
        #expect(r.stdout.contains("    Reviews (id: 3)\n"))
        #expect(r.stdout.contains("    Editorial (id: 2)\n"))
        #expect(r.stdout.contains("  Work (id: 4)\n"))
        #expect(r.stdout.contains("\n3 lists, 1 group\n"))
    }

    @Test func listsTableLabelsGroupRows() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--format", "table"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("│ 1  │ Writing"))
        #expect(r.stdout.contains("group"))
        #expect(r.stdout.contains("2 lists"))
        #expect(r.stdout.contains("│   Reviews"))
    }

    // MARK: - stats

    @Test func statsCountsListsWithoutGroups() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["stats", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(obj?["lists"] as? Int == 3)   // Editorial, Reviews, Work — not the group
    }

    // MARK: - resolution

    @Test func resolveListRefReportsGroupsWithChildren() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        guard case let .group(id, title, uuid, children) = store.resolveListRef(name: "Writing", listId: nil) else {
            Issue.record("expected group by name"); return
        }
        #expect(id == 1)
        #expect(title == "Writing")
        #expect(uuid == "CK-1")
        #expect(children.map(\.title) == ["Reviews", "Editorial"])
        guard case .group = store.resolveListRef(name: nil, listId: 1) else {
            Issue.record("expected group by id"); return
        }
        // An ordinary list still resolves normally.
        guard case .found = store.resolveListRef(name: "Editorial", listId: nil) else {
            Issue.record("expected found"); return
        }
    }

    @Test func addRefusesAGroupTargetBeforeWriting() async throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", list: "Writing", json: false, store: store, writer: m,
                                  private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: 'Writing' is a Reminders list group, not a writable list."
            + " Use one of its child lists: Reviews (id 3), Editorial (id 2)\n")
        #expect(m.calls.isEmpty)
    }

    @Test func addRefusesAGroupTargetByListId() async throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", listId: 1, json: false, store: store, writer: m,
                                  private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("is a Reminders list group, not a writable list."))
        #expect(m.calls.isEmpty)
    }

    @Test func editRefusesAGroupAsMoveTarget() async throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 10, list: "Writing", json: false, store: store, writer: m,
                                   private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("is a Reminders list group, not a writable list."))
        #expect(m.calls.isEmpty)
    }

    @Test func emptyGroupStillRefusesReminderTargets() async throws {
        let dir = try emptyGroupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", list: "Writing", json: false, store: store, writer: m,
                                  private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: 'Writing' is a Reminders list group, not a writable list.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - show

    @Test func showGroupListsEveryChildListsReminders() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Writing"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.hasPrefix("Writing (group):\n"))
        // Child lists in group order; within Editorial, Reminders' manual order wins.
        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.contains("  Reviews:"))
        #expect(lines.contains("  Editorial:"))
        let titles = lines.filter { $0.contains("#") }
        #expect(titles.count == 3)
        #expect(titles[0].contains("Review One"))
        #expect(titles[1].contains("Editorial B"))
        #expect(titles[2].contains("Editorial A"))
        #expect(r.stdout.hasSuffix("\n3 reminders\n"))
    }

    @Test func showGroupByListIdMatchesTheNamePath() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let byName = try CLIRunner.run(["show", "Writing"], storeDir: dir)
        let byId = try CLIRunner.run(["show", "--list-id", "1"], storeDir: dir)
        #expect(byId.exit == 0)
        #expect(byId.stdout == byName.stdout)
    }

    @Test func showGroupJSONNamesTheChildListAndGroup() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Writing", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(arr?.map { $0["title"] as? String } ?? [] == ["Review One", "Editorial B", "Editorial A"])
        let first = arr?.first
        let list = first?["list"] as? [String: Any]
        #expect(list?["id"] as? Int == 3)
        #expect(list?["title"] as? String == "Reviews")
        #expect(list?["objectUUID"] as? String == "CK-3")
        let group = first?["group"] as? [String: Any]
        #expect(group?["id"] as? Int == 1)
        #expect(group?["title"] as? String == "Writing")
        #expect(group?["objectUUID"] as? String == "CK-1")
    }

    @Test func showGroupTableSplitsByChildList() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Writing", "--format", "table"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.hasPrefix("Writing (group):\n"))
        #expect(r.stdout.contains("  Reviews:\n"))
        #expect(r.stdout.contains("  Editorial:\n"))
        // Per-child tables are already headed by their list, so they drop the List column.
        #expect(r.stdout.contains("│ ID  │ Title       │ Due │ Pri │"))
        #expect(!r.stdout.contains("List"))
        #expect(r.stdout.hasSuffix("\n3 reminders\n"))
    }

    @Test func showGroupWithCompletedIncludesFinishedChildReminders() throws {
        let dir = try groupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Writing", "--completed"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Editorial Done"))
        #expect(r.stdout.hasSuffix("\n4 reminders\n"))
    }

    @Test func showEmptyGroupReportsNoChildLists() throws {
        let dir = try emptyGroupStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let human = try CLIRunner.run(["show", "Writing"], storeDir: dir)
        #expect(human.exit == 0)
        #expect(human.stdout == "No child lists in group 'Writing'\n")
        let json = try CLIRunner.run(["show", "Writing", "--json"], storeDir: dir)
        #expect(json.stdout == "[]\n")
    }

    @Test func showGroupWithoutRemindersReportsTheGroup() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP) VALUES (1,3,'Writing','CK-1',0,1);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZPARENTLIST) VALUES (2,3,'Editorial','CK-2',0,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Writing"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No active reminders in group 'Writing'\n")
    }
}
