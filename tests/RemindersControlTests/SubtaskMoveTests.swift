import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `reminder-move --parent/--top-level` and subtask reordering (upstream 3eb076b): the reminder
/// keeps its id, every refusal happens before the write, and the new structure is read back.
@Suite struct SubtaskMoveTests {
    /// Inbox (pk 12) records PARENT, SUB-A, SUB-B, MOVING, OTHER. SUB-A and SUB-B are PARENT's
    /// subtasks; PARENT sits in section 'Doing'. Work (pk 13) holds ELSEWHERE.
    private func fixture(order: String = #"["PARENT","SUB-A","SUB-B","MOVING","OTHER"]"#,
                         parentDeleted: Bool = false) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZREMINDERIDSMERGEABLEORDERING_V2_JSON,ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA)
                  VALUES (12,3,'Inbox','CK-L',0,?,'{"memberships":[{"memberID":"PARENT","groupID":"S1","isObsolete":false}]}');
                INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (13,3,'Work','CK-W',0);
                INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (10,'Doing',12,'S1',0);
                """, arguments: [order])
            for (pk, ckid, list, parent) in [(100, "PARENT", 12, 0), (101, "MOVING", 12, 0), (102, "OTHER", 12, 0),
                                             (201, "SUB-A", 12, 100), (202, "SUB-B", 12, 100), (300, "ELSEWHERE", 13, 0)] {
                try db.execute(sql: """
                    INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZCKIDENTIFIER,ZLIST,ZPARENTREMINDER,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
                    VALUES (?,?,?,?,?,1,0,?)
                    """, arguments: [pk, ckid.capitalized, ckid, list, parent == 0 ? nil : parent, parentDeleted && pk == 100 ? 1 : 0])
            }
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Stands in for Reminders' save: gives `reminder` its new parent (and, when given, the list's
    /// new order); an assigned section is recorded in the list's membership record.
    private func reminders(_ dir: URL, reminder: Int, parent: Int?, order: String? = nil) -> MockPrivateWriter {
        let p = MockPrivateWriter()
        p.onCall = { call in
            let queue = try? DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path)
            try? queue?.write { db in
                switch call {
                case .moveReminderInHierarchy:
                    try db.execute(sql: "UPDATE ZREMCDREMINDER SET ZPARENTREMINDER = ? WHERE Z_PK = ?", arguments: [parent, reminder])
                    if let order {
                        try db.execute(sql: "UPDATE ZREMCDBASELIST SET ZREMINDERIDSMERGEABLEORDERING_V2_JSON = ? WHERE Z_PK = 12", arguments: [order])
                    }
                case .assignSection(let id, let sectionId):
                    let blob = #"{"memberships":[{"memberID":"PARENT","groupID":"S1","isObsolete":false},{"memberID":"\#(id)","groupID":"\#(sectionId)","isObsolete":false}]}"#
                    try db.execute(sql: "UPDATE ZREMCDBASELIST SET ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA = ? WHERE Z_PK = 12", arguments: [blob])
                default: break
                }
            }
        }
        return p
    }

    private func move(_ request: ReminderMoveRequest, json: Bool = true, store: RemindersStore,
                      private p: MockPrivateWriter) async -> WriteOutcome {
        await WriteDispatch.perform(json: json) {
            try await ReminderMove.perform(request, json: json, store: store, private: p, readback: .immediate)
        }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - Nesting

    @Test func nestingPlacesTheReminderAfterTheLastSubtask() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir, reminder: 101, parent: 100)
        let out = await move(ReminderMoveRequest(id: 101, parent: 100), store: store, private: p)
        #expect(p.calls == [.moveReminderInHierarchy(id: "MOVING", listId: "CK-L", parentId: "PARENT", position: "after", anchorId: "SUB-B")])
        let payload = try json(out.stdout)
        #expect(payload["hierarchy"] as? String == "nested")
        #expect(payload["parentId"] as? Int == 100)
        #expect(payload["position"] as? String == "last")
        #expect(payload["anchorId"] as? Int == 202)
        #expect(payload["verified"] as? Bool == true)
        #expect(store.reminder(pk: 101)?.int("ZPARENTREMINDER") == 100)
    }

    @Test func nestingWithAPositionPlacesAmongTheSubtasks() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir, reminder: 101, parent: 100, order: #"["PARENT","SUB-A","MOVING","SUB-B","OTHER"]"#)
        let out = await move(ReminderMoveRequest(id: 101, before: 202, parent: 100), store: store, private: p)
        #expect(p.calls == [.moveReminderInHierarchy(id: "MOVING", listId: "CK-L", parentId: "PARENT", position: "before", anchorId: "SUB-B")])
        #expect(out.exitCode == 0)
    }

    @Test func nestingUnderAReminderWithoutSubtasksAppends() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir, reminder: 101, parent: 102)
        let out = await move(ReminderMoveRequest(id: 101, first: true, parent: 102), store: store, private: p)
        #expect(p.calls == [.moveReminderInHierarchy(id: "MOVING", listId: "CK-L", parentId: "OTHER", position: "append", anchorId: nil)])
        #expect(try json(out.stdout)["anchorId"] == nil)
    }

    // MARK: - Reordering and unnesting

    @Test func aSubtaskMovedWithAPositionStaysUnderItsParent() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir, reminder: 202, parent: 100, order: #"["PARENT","SUB-B","SUB-A","MOVING","OTHER"]"#)
        let out = await move(ReminderMoveRequest(id: 202, before: 201), json: false, store: store, private: p)
        #expect(p.calls == [.moveReminderInHierarchy(id: "SUB-B", listId: "CK-L", parentId: "PARENT", position: "before", anchorId: "SUB-A")])
        #expect(out.stdout == "Moved #202 under #100 Parent (before #201) in list 'Inbox'.\n")
    }

    @Test func topLevelPlacesASubtaskAfterItsFormerParentAndJoinsItsSection() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir, reminder: 201, parent: nil)
        let out = await move(ReminderMoveRequest(id: 201, topLevel: true), store: store, private: p)
        #expect(p.calls == [
            .moveReminderInHierarchy(id: "SUB-A", listId: "CK-L", parentId: nil, position: "after", anchorId: "PARENT"),
            .assignSection(id: "SUB-A", sectionId: "S1"),
        ])
        let payload = try json(out.stdout)
        #expect(payload["hierarchy"] as? String == "unnested")
        #expect(payload["parentId"] is NSNull)
        #expect(payload["section"] as? String == "Doing")
    }

    @Test func topLevelAtAnEndLeavesSectionsAlone() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = reminders(dir, reminder: 201, parent: nil, order: #"["PARENT","SUB-B","MOVING","OTHER","SUB-A"]"#)
        let out = await move(ReminderMoveRequest(id: 201, last: true, topLevel: true), store: store, private: p)
        #expect(p.calls == [.moveReminderInHierarchy(id: "SUB-A", listId: "CK-L", parentId: nil, position: "after", anchorId: "OTHER")])
        #expect(try json(out.stdout)["section"] == nil)
    }

    // MARK: - Refusals

    @Test func impossibleHierarchiesAreRefusedBeforeWriting() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(ReminderMoveRequest, String)] = [
            (ReminderMoveRequest(id: 101, parent: 101), "a reminder cannot be its own parent."),
            (ReminderMoveRequest(id: 101, parent: 201), "#201 is itself a subtask. Reminders allows one level of subtasks."),
            (ReminderMoveRequest(id: 100, parent: 102), "#100 has its own subtasks. Reminders allows one level of subtasks."),
            (ReminderMoveRequest(id: 101, parent: 300), "#300 is in list 'Work'. Move #101 there first: remctl edit 101 -l Work"),
            (ReminderMoveRequest(id: 101, before: 102, parent: 100), "anchor #102 is not a subtask of #100."),
            (ReminderMoveRequest(id: 101, topLevel: true),
             "#101 is already a top-level reminder. Pass --before, --after, --first, or --last to reorder it."),
        ]
        for (request, message) in cases {
            let p = MockPrivateWriter()
            let out = await move(request, json: false, store: store, private: p)
            #expect(out.stderr == "Error: \(message)\n")
            #expect(p.calls.isEmpty)
        }
    }

    @Test func aLevelReminderHasNotFullyRecordedIsRefused() async throws {
        let (store, dir) = try fixture(order: #"["PARENT","SUB-A","MOVING","OTHER"]"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await move(ReminderMoveRequest(id: 101, parent: 100), store: store, private: p)
        #expect(try json(out.stderr)["code"] as? String == "level_unrecorded")
        #expect(p.calls.isEmpty)
    }

    @Test func unnestingNeedsTheFormerParent() async throws {
        let (store, dir) = try fixture(parentDeleted: true); defer { try? FileManager.default.removeItem(at: dir) }
        let out = await move(ReminderMoveRequest(id: 201, topLevel: true), json: false, store: store, private: MockPrivateWriter())
        #expect(out.stderr == "Error: former parent #100 not found. Pass --before, --after, --first, or --last.\n")
    }

    @Test func aStructureTheStoreNeverShowsIsUnverified() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = await move(ReminderMoveRequest(id: 101, parent: 100), store: store, private: MockPrivateWriter())
        #expect(try json(out.stderr)["code"] as? String == "hierarchy_unverified")
    }

    @Test func hierarchyFlagsWorkOnlyWithinAList() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var request = ReminderMoveRequest(id: 101, parent: 100); request.smartList = "Focus"
        let out = await move(request, json: false, store: store, private: MockPrivateWriter())
        #expect(out.stderr == "Error: --parent and --top-level work within a list, not a smart list.\n")
    }
}
