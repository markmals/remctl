import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `--smart-list`/`--smart-list-id` with `--section`/`--section-id` (upstream caf7423, c6a2429)
/// and the shared newest-`modifiedOn` membership rule (upstream 231fb1f, c6b13c4).
@Suite struct SmartListSectionTests {
    /// Projects (pk 1) has its own 'Next' (SECTION-1) and 'Later' (SECTION-2); REM-1 (#42) lives
    /// there. Focus (pk 2) is a custom smart list with sections 'Next' (FOCUS-NEXT) and 'Later'
    /// (FOCUS-LATER); Today (pk 3) is built in.
    private func fixture() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            ALTER TABLE ZREMCDBASESECTION ADD COLUMN ZSMARTLIST INTEGER;
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (1,3,'Projects','CK-1',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZSMARTLISTTYPE)
              VALUES (2,4,'Focus','SMART-FOCUS',0,'com.apple.reminders.smartlist.custom');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZSMARTLISTTYPE)
              VALUES (3,4,NULL,'SMART-TODAY',0,'com.apple.reminders.smartlist.today');
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (10,'Next',1,'SECTION-1',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (11,'Later',1,'SECTION-2',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZSMARTLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (20,'Next',2,'FOCUS-NEXT',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZSMARTLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (21,'Later',2,'FOCUS-LATER',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Draft',1,1,0,0,'REM-1');
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    private func execute(_ dir: URL, _ sql: String, _ arguments: StatementArguments = []) {
        let queue = try? DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path)
        try? queue?.write { try $0.execute(sql: sql, arguments: arguments) }
    }

    private func setMemberships(_ dir: URL, pk: Int, _ entries: [[String: Any]]) {
        let data = try! JSONSerialization.data(withJSONObject: ["memberships": entries])
        execute(dir, "UPDATE ZREMCDBASELIST SET ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA = ? WHERE Z_PK = ?",
                [String(decoding: data, as: UTF8.self), pk])
    }

    private func entry(_ group: String, _ modifiedOn: Double? = nil, obsolete: Bool = false) -> [String: Any] {
        var membership: [String: Any] = ["memberID": "REM-1", "groupID": group, "isObsolete": obsolete]
        if let modifiedOn { membership["modifiedOn"] = modifiedOn }
        return membership
    }

    /// A private writer whose smart-list section write leaves `written` in Focus's membership record.
    private func writer(_ dir: URL, written: [[String: Any]]? = nil) -> MockPrivateWriter {
        let p = MockPrivateWriter()
        p.onCall = { call in
            guard case let .assignSmartListSection(id, sectionId, _) = call else { return }
            self.setMemberships(dir, pk: 2, written ?? [["memberID": id, "groupID": sectionId, "isObsolete": false]])
        }
        return p
    }

    private func target(_ store: RemindersStore, section: String? = nil, sectionId: String? = nil,
                        newSection: String? = nil, smartList: String? = nil, smartListId: Int? = nil) throws -> SectionTarget? {
        try resolveSectionTarget(store: store, listPk: 1, section: section, sectionId: sectionId,
                                 newSection: newSection, smartList: smartList, smartListId: smartListId)
    }

    private func apply(_ store: RemindersStore, _ target: SectionTarget?, section: String? = nil,
                       private p: MockPrivateWriter) async throws -> [PrivateResult] {
        try await PrivateChanges.apply(
            reminderCkid: "REM-1", url: nil, tags: [], section: section, sectionId: nil, newSection: nil,
            sectionTarget: target, flagged: nil, urgent: nil, earlyReminder: nil, store: store, listPk: 1,
            writer: MockWriter(), private: p, readback: .immediate)
    }

    private func message(_ body: () throws -> Any?) -> String? {
        do { _ = try body(); return nil } catch let error as CLIError { return error.message } catch { return "\(error)" }
    }

    // MARK: - Targeting

    @Test func aSmartListTargetsItsOwnSectionByNameOrIdAndIsVerified() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        for smartTarget in [try target(store, section: "next", smartList: "Focus"),
                            try target(store, sectionId: "x-apple-reminderkit://REMCDSmartListSection/FOCUS-NEXT", smartListId: 2)] {
            let p = writer(dir)
            let results = try await apply(store, smartTarget, private: p)
            #expect(p.calls == [.assignSmartListSection(id: "REM-1", sectionId: "FOCUS-NEXT", smartListId: "SMART-FOCUS")])
            #expect(results.first?.fields["smartList"] == .string("Focus"))
            #expect(results.first?.fields["section"] == .string("Next"))
            #expect(results.first?.fields["verified"] == .bool(true))
        }
        // Without --smart-list, --section means the reminder's own list, whatever smart lists hold.
        #expect(try target(store, section: "Next") == .list(sectionId: "SECTION-1"))
    }

    @Test func smartListTargetsAreRefusedBeforeWriting() throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        execute(dir, "INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZSMARTLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (22,'Next',2,'FOCUS-NEXT-2',0)")
        #expect(message { try target(store, section: "Next", smartList: "Today") }
                == "'Today' is a built-in smart list; only custom smart lists have sections.")
        #expect(message { try target(store, section: "Someday", smartList: "Focus") }
                == "section not found: Someday in smart list 'Focus'. Its sections are: 'Next' (FOCUS-NEXT), 'Later' (FOCUS-LATER), 'Next' (FOCUS-NEXT-2)")
        #expect(message { try target(store, section: "Next", smartList: "Focus") }
                == "multiple sections named 'Next' in smart list 'Focus'. Use --section-id with one of: 'Next' (FOCUS-NEXT), 'Next' (FOCUS-NEXT-2)")
    }

    @Test func aSmartListNeedsExactlyOneExistingSectionFlag() {
        let (store, dir) = try! fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(message { try target(store, smartList: "Focus") } == "--smart-list and --smart-list-id need --section or --section-id.")
        #expect(message { try target(store, section: "Next", sectionId: "FOCUS-NEXT", smartList: "Focus") }
                == "pass either --section or --section-id, not both.")
        #expect(message { try target(store, section: "Next", newSection: "Later", smartListId: 2) }
                == "--new-section creates a section in the reminder's list; it cannot be combined with --smart-list.")
    }

    @Test func aSmartListSectionWriteThatDoesNotReadBackFails() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = writer(dir, written: [entry("FOCUS-LATER")])
        do {
            _ = try await apply(store, try target(store, section: "Next", smartList: "Focus"), private: p)
            Issue.record("expected the unverified write to fail")
        } catch let failure as PrivateStepFailure {
            #expect(failure.action == "assign_smart_list_section")
            #expect(failure.message == "ReminderKit reported success, but the reminder is not in section 'Next' of smart list 'Focus'.")
        }
    }

    @Test func theWriteGoesToTheSectionValidatedBeforeARename() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let smartTarget = try target(store, section: "Next", smartList: "Focus")
        let listTarget = try target(store, section: "Next")
        // A sync renames both validated sections and hands their old name to new ones.
        execute(dir, "UPDATE ZREMCDBASESECTION SET ZDISPLAYNAME = 'Renamed' WHERE Z_PK IN (10, 20)")
        execute(dir, "INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZSMARTLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (30,'Next',2,'FOCUS-NEW',0)")
        execute(dir, "INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (31,'Next',1,'SECTION-NEW',0)")
        let p = writer(dir)
        _ = try await apply(store, smartTarget, section: "Next", private: p)
        _ = try await apply(store, listTarget, section: "Next", private: p)
        #expect(p.calls == [
            .assignSmartListSection(id: "REM-1", sectionId: "FOCUS-NEXT", smartListId: "SMART-FOCUS"),
            .assignSection(id: "REM-1", sectionId: "SECTION-1"),
        ])
    }

    // MARK: - add / edit

    @Test func editResolvesTheSmartListSectionBeforeTheEventKitWrite() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(), p = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, title: "Renamed", section: "Someday", smartList: "Focus", json: false,
                                   store: store, writer: m, private: p)
        }
        #expect(out.stderr.hasPrefix("Error: section not found: Someday in smart list 'Focus'."))
        #expect(m.calls.isEmpty)
        #expect(p.calls.isEmpty)
    }

    @Test func addReportsAnUnresolvedSectionAsAStructuredErrorUnderJSON() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", list: "Projects", section: "Someday", smartListId: 2, json: true,
                                        store: store, writer: m, private: MockPrivateWriter())
        let payload = try #require(JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        #expect(payload["code"] as? String == "section_not_found")
        #expect(m.calls.isEmpty)
    }

    @Test func smartListsListACustomSmartListsSectionsWithTheirIds() throws {
        let (_, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["smart-lists", "--json"], storeDir: dir)
        let lists = try #require(JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]])
        let focus = lists.first { $0["name"] as? String == "Focus" }
        #expect(focus?["sections"] as? [[String: String]] == [["id": "FOCUS-NEXT", "name": "Next"], ["id": "FOCUS-LATER", "name": "Later"]])
        #expect(lists.first { $0["name"] as? String == "Today" }?["sections"] == nil)
        let human = try CLIRunner.run(["smart-lists"], storeDir: dir)
        #expect(human.stdout.contains("    - Next (FOCUS-NEXT)\n"))
    }

    // MARK: - Membership rule

    @Test func smartListReadbackFollowsTheNewestConflictingMembership() {
        let (store, dir) = try! fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = entry("FOCUS-LATER", 100), fresh = entry("FOCUS-NEXT", 200)
        let cases: [([[String: Any]], String?)] = [
            ([stale, fresh], "FOCUS-NEXT"),
            ([fresh, stale], "FOCUS-NEXT"),
            // A newer obsolete entry takes the reminder out of the older section.
            ([stale, entry("FOCUS-LATER", 300, obsolete: true)], nil),
            // Without dates nothing orders the conflict, so no section verifies.
            ([entry("FOCUS-LATER"), entry("FOCUS-NEXT")], nil),
            ([entry("FOCUS-NEXT", 100), entry("FOCUS-LATER", 100)], nil),
        ]
        for (memberships, expected) in cases {
            setMemberships(dir, pk: 2, memberships)
            #expect(store.reminderSectionCkid(listPk: 2, reminderCkid: "rem-1", smartList: true) == expected)
        }
    }

    @Test func listSectionReadersShareTheNewestMembershipRule() {
        let (store, dir) = try! fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        setMemberships(dir, pk: 1, [entry("SECTION-2", 200), entry("SECTION-1", 100)])
        #expect(store.sectionMemberships(1) == ["REM-1": "Later"])
        #expect(store.reminderSectionCkid(listPk: 1, reminderCkid: "rem-1") == "SECTION-2")
        #expect(store.sectionMemberCounts(listPk: 1) == ["SECTION-2": 1])
    }

    @Test func undatedConflictsKeepTheLiveSectionForDisplayOnly() {
        let (store, dir) = try! fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        setMemberships(dir, pk: 1, [entry("SECTION-1", obsolete: true), entry("SECTION-2", 200)])
        #expect(store.sectionMemberships(1) == ["REM-1": "Later"])
        #expect(store.sectionMemberCounts(listPk: 1) == ["SECTION-2": 1])
        #expect(store.reminderSectionCkid(listPk: 1, reminderCkid: "rem-1") == nil)
    }
}
