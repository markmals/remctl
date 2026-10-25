import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `reminder-move` (upstream 374c24d): reorders a reminder within its list, or within an
/// unsectioned custom smart list's manual order, and reports it only once the store shows it.
@Suite struct ReminderMoveTests {
    /// Inbox (pk 12) orders A, MOVE, B, C; LOOSE is in Inbox but not in that record yet, and SUB
    /// is A's subtask. Work (pk 13) holds X. Focus (pk 7) is a custom smart list whose manual order
    /// is MOVE, B, X; Today (pk 8) is built in.
    private func fixture(smartListSection: Bool = false) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            ALTER TABLE ZREMCDOBJECT ADD COLUMN ZLISTTYPERAWVALUE INTEGER;
            ALTER TABLE ZREMCDOBJECT ADD COLUMN ZLISTID TEXT;
            ALTER TABLE ZREMCDOBJECT ADD COLUMN ZHINTDATA BLOB;
            ALTER TABLE ZREMCDBASESECTION ADD COLUMN ZSMARTLIST INTEGER;
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME TEXT);
            INSERT INTO Z_PRIMARYKEY VALUES (33, 'REMCDManualSortHint_v1');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZREMINDERIDSMERGEABLEORDERING_V2_JSON)
              VALUES (12,3,'Inbox','CK-L',0,'["A","MOVE","B","C"]');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (13,3,'Work','CK-W',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZSMARTLISTTYPE)
              VALUES (7,4,'Focus','SMART',0,'com.apple.reminders.smartlist.custom');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZSMARTLISTTYPE)
              VALUES (8,4,'Today','TODAY',0,'com.apple.reminders.smartlist.today');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZLISTTYPERAWVALUE,ZLISTID,ZHINTDATA)
              VALUES (50,33,0,'HINT',2,'SMART',CAST(X'01' || CAST('{"topLevelElementIDs":["MOVE","B","X"],"secondaryLevelElementIDsByTopLevelElementID":{}}' AS BLOB) AS BLOB));
            """)
            for (pk, title, ckid, list, parent) in [(100, "A", "A", 12, 0), (101, "Move me", "MOVE", 12, 0), (102, "B", "B", 12, 0),
                                                    (103, "C", "C", 12, 0), (104, "Sub", "SUB", 12, 100),
                                                    (105, "Loose", "LOOSE", 12, 0), (200, "X", "X", 13, 0)] {
                try db.execute(sql: """
                    INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZCKIDENTIFIER,ZLIST,ZPARENTREMINDER,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
                    VALUES (?,?,?,?,?,1,0,0)
                    """, arguments: [pk, title, ckid, list, parent == 0 ? nil : parent])
            }
            if smartListSection {
                try db.execute(sql: "INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZSMARTLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (60,'Next',7,'SS1',0)")
            }
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Stands in for the save Reminders makes: rewrites the list order or the smart list's hint.
    private func landing(_ dir: URL, listOrder: String? = nil, hint: String? = nil) -> (MockPrivateWriter.Call) -> Void {
        { _ in
            let queue = try? DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path)
            try? queue?.write { db in
                if let listOrder {
                    try db.execute(sql: "UPDATE ZREMCDBASELIST SET ZREMINDERIDSMERGEABLEORDERING_V2_JSON = ? WHERE Z_PK = 12", arguments: [listOrder])
                }
                if let hint {
                    try db.execute(sql: "UPDATE ZREMCDOBJECT SET ZHINTDATA = ? WHERE Z_PK = 50",
                                   arguments: [Data([0x01]) + Data(#"{"topLevelElementIDs":\#(hint)}"#.utf8)])
                }
            }
        }
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

    // MARK: - Lists

    @Test func listMoveIsReportedOnceTheStoredOrderMatches() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.onCall = landing(dir, listOrder: #"["A","C","MOVE","B"]"#)
        let out = await move(ReminderMoveRequest(id: 103, before: 101), store: store, private: p)
        #expect(p.calls == [.moveReminderInList(id: "C", listId: "CK-L", position: "before", anchorId: "MOVE")])
        let payload = try json(out.stdout)
        #expect(payload["verified"] as? Bool == true)
        #expect(payload["anchorId"] as? Int == 101)
        #expect(payload["list"] as? String == "Inbox")
        #expect(payload["verifiedAfterHelperError"] == nil)
    }

    @Test func listMoveFailsWhileTheStoredOrderIsUnchanged() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = await move(ReminderMoveRequest(id: 101, last: true), store: store, private: MockPrivateWriter())
        #expect(try json(out.stderr)["code"] as? String == "order_unverified")
    }

    @Test func aHelperErrorWhoseMoveLandedIsStillVerified() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "error", message: "Couldn’t communicate with a helper application.")
        p.onCall = landing(dir, listOrder: #"["MOVE","A","B","C"]"#)
        let out = await move(ReminderMoveRequest(id: 101, first: true), store: store, private: p)
        #expect(try json(out.stdout)["verifiedAfterHelperError"] as? Bool == true)
    }

    @Test func aHelperErrorWithNoMoveReportsTheHelperMessage() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "error", message: "Reminder is not in the requested list")
        let out = await move(ReminderMoveRequest(id: 101, first: true), json: false, store: store, private: p)
        #expect(out.stderr == "Error: Reminder is not in the requested list\n")
    }

    @Test func remindersInDifferentListsNeedASmartList() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await move(ReminderMoveRequest(id: 101, after: 200), json: false, store: store, private: p)
        #expect(out.stderr == "Error: reminders in different lists require --smart-list or --smart-list-id.\n")
        #expect(p.calls.isEmpty)
    }

    @Test func anAnchorMissingFromTheOrderIsRefused() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await move(ReminderMoveRequest(id: 101, before: 105), store: store, private: p)
        #expect(try json(out.stderr)["code"] as? String == "anchor_unpositioned")
        #expect(p.calls.isEmpty)
    }

    @Test func subtasksAreNotReorderedAsListReminders() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await move(ReminderMoveRequest(id: 104, last: true), store: store, private: p)
        #expect(try json(out.stderr)["code"] as? String == "subtask_move_unsupported")
        #expect(p.calls.isEmpty)
    }

    @Test func exactlyOnePlacementIsRequired() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let none = await move(ReminderMoveRequest(id: 101), json: false, store: store, private: MockPrivateWriter())
        #expect(none.stderr == "Error: pass exactly one of --before, --after, --first, or --last.\n")
        let itself = await move(ReminderMoveRequest(id: 101, before: 101), json: false, store: store, private: MockPrivateWriter())
        #expect(itself.stderr == "Error: a reminder cannot be positioned relative to itself.\n")
    }

    // MARK: - Custom smart lists

    @Test func smartListMoveWritesTheWholeManualOrder() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.onCall = landing(dir, hint: #"["B","MOVE","X"]"#)
        var request = ReminderMoveRequest(id: 101, before: 200); request.smartList = "focus"
        let out = await move(request, store: store, private: p)
        #expect(p.calls == [.setSmartListManualOrder(id: "MOVE", smartListId: "SMART", manualOrderingId: "HINT",
                                                     topLevelElementIds: ["B", "MOVE", "X"])])
        let payload = try json(out.stdout)
        #expect(payload["smartList"] as? String == "Focus")
        #expect(payload["list"] == nil)
        #expect(payload["verified"] as? Bool == true)
    }

    @Test func sectionedSmartListsAreRefusedBeforeWriting() async throws {
        let (store, dir) = try fixture(smartListSection: true); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        var request = ReminderMoveRequest(id: 101, first: true); request.smartListId = 7
        let out = await move(request, store: store, private: p)
        #expect(try json(out.stderr)["code"] as? String == "sectioned_smart_list")
        #expect(p.calls.isEmpty)
    }

    @Test func builtInSmartListsAreRefused() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var request = ReminderMoveRequest(id: 101, first: true); request.smartList = "Today"
        let out = await move(request, store: store, private: MockPrivateWriter())
        #expect(try json(out.stderr)["code"] as? String == "smart_list_not_custom")
    }

    @Test func aReminderWithoutAManualPositionIsRefused() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var request = ReminderMoveRequest(id: 103, first: true); request.smartList = "Focus"
        let out = await move(request, json: false, store: store, private: MockPrivateWriter())
        #expect(out.stderr == "Error: #103 has no persisted position in smart list 'Focus'.\n")
    }

    // MARK: - Ordering helpers

    @Test func reorderPlacesRelativeToAnAnchorOrAtAnEnd() {
        let ordering = ["A", "MOVE", "B", "C"]
        #expect(reorderIdentifiers(ordering, moving: "MOVE", position: "after", anchor: "c") == ["A", "B", "C", "MOVE"])
        #expect(reorderIdentifiers(ordering, moving: "move", position: "first", anchor: nil) == ["MOVE", "A", "B", "C"])
        #expect(reorderIdentifiers(ordering, moving: "MOVE", position: "last", anchor: nil) == ["A", "B", "C", "MOVE"])
        #expect(reorderIdentifiers(ordering, moving: "MOVE", position: "before", anchor: "GONE") == nil)
    }

    @Test func manualSortHintsDecodeWithOrWithoutTheLeadingByte() {
        let body = #"{"topLevelElementIDs":["A","B"],"secondaryLevelElementIDsByTopLevelElementID":{"A":["S"]}}"#
        let prefixed = decodeManualSortHint(DatabaseValue(value: Data([0x01]) + Data(body.utf8)))
        #expect(prefixed?.topLevel == ["A", "B"])
        #expect(prefixed?.secondary == ["A": ["S"]])
        #expect(decodeManualSortHint(DatabaseValue(value: body))?.topLevel == ["A", "B"])
        #expect(decodeManualSortHint(DatabaseValue(value: #"{"topLevelElementIDs":["A",""]}"#)) == nil)
    }
}
