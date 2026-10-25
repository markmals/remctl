import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `edit -l/--list-id` list moves: the verified ReminderKit clone-delete for parents with
/// subtasks (upstream ed5e982) and for EventKit container-boundary rejections (upstream cd31b51).
@Suite struct ListMoveTests {
    /// Work (pk 10, CK-W) holds parent #42 with subtasks #43/#44. Home (pk 11, CK-H) already
    /// holds the clone the private helper reports (#90 with #91/#92), as the store would show
    /// it once ReminderKit's save lands.
    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (11,3,'Home',0,'CK-H')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Parent',10,1,0,0,'ABC')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZPARENTREMINDER) VALUES (43,'Sub 1',10,1,0,0,'S1',42)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZPARENTREMINDER) VALUES (44,'Sub 2',10,1,1,0,'S2',42)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (90,'Parent',11,1,0,0,'NEW-CK')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZPARENTREMINDER) VALUES (91,'Sub 1',11,1,0,0,'NS1',90)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZPARENTREMINDER) VALUES (92,'Sub 2',11,1,1,0,'NS2',90)")
            // A childless reminder in Work, for the ordinary EventKit move.
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (50,'Solo',10,1,0,0,'SOLO')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (93,'Solo',11,1,0,0,'SOLO-NEW')")
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    private func clonedAs(_ newId: String) -> MockPrivateWriter {
        let p = MockPrivateWriter()
        p.cloneResult = PrivateResult(status: "cloned", fields: ["newId": .string(newId)])
        return p
    }

    // MARK: - Parent with subtasks

    @Test func parentWithSubtasksMovesByCloneDelete() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let p = clonedAs("NEW-CK")
        let out = try await Edit.perform(id: 42, list: "Home", json: false, store: s, writer: m, private: p)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Moved #42 -> #90\nList: Home\nSubtasks: 2\n")
        #expect(p.calls == [.cloneReminderTree(id: "ABC", listId: "CK-H", childIds: ["S1", "S2"])])
        #expect(m.calls == [.delete(id: "ABC")])
    }

    @Test func cloneDeleteJSONCarriesOldIdAndMethod() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Edit.perform(id: 42, list: "Home", json: true, store: s, writer: MockWriter(),
                                         private: clonedAs("NEW-CK"))
        #expect(out.stdout == #"{"status": "updated", "id": 90, "oldId": 42, "list": "Home", "objectUUID": "NEW-CK", "subtasksMoved": 2, "method": "clone-delete", "originalDeleted": true}"# + "\n")
    }

    @Test func cloneDeleteRefusesToCombineWithOtherEdits() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let p = clonedAs("NEW-CK")
        let out = try await Edit.perform(id: 42, title: "Renamed", list: "Home", json: false,
                                         store: s, writer: m, private: p)
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: moving a parent reminder with subtasks cannot currently be combined with other edits. "
            + "Move it first, then edit the cloned reminder returned by remctl.\n")
        #expect(m.calls.isEmpty)
        #expect(p.calls.isEmpty)
    }

    @Test func cloneDeleteRefusalIsStructuredInJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Edit.perform(id: 42, list: "Home", notes: "x", json: true,
                                         store: s, writer: MockWriter(), private: clonedAs("NEW-CK"))
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains(#""code": "list_move_with_subtasks_conflicts_with_edits""#))
    }

    @Test func unverifiedCloneLeavesTheOriginalInPlace() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, list: "Home", json: false, store: s, writer: m,
                                         private: clonedAs("MISSING-CK"), cloneAttempts: 1, cloneDelay: 0)
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("was not visible in the target list with the expected subtask count"))
        #expect(out.stderr.contains("Original #42 was not deleted."))
        #expect(m.calls.isEmpty)
    }

    @Test func failedPrivateCloneIsReported() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.cloneResult = PrivateResult(status: "error", message: "ReminderKit clone save failed")
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, list: "Home", json: true, store: s, writer: m, private: p)
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains(#""code": "clone_move_failed""#))
        #expect(out.stderr.contains("ReminderKit clone save failed"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - Ordinary moves

    @Test func childlessMoveStaysOnEventKitAndCarriesTheListCKID() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let p = MockPrivateWriter()
        let out = try await Edit.perform(id: 50, list: "Home", json: false, store: s, writer: m, private: p)
        #expect(out.stdout == "Updated #50\nList: Home\n")
        #expect(p.calls.isEmpty)
        guard m.calls.count == 1, case let .update(id, write) = m.calls[0] else {
            Issue.record("expected one EventKit update, got \(m.calls)"); return
        }
        #expect(id == "SOLO")
        #expect(write.list == "Home")
        #expect(write.listId == "CK-H")
    }

    @Test func containerBoundaryRejectionFallsBackToCloneDelete() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.updateError = WriteError("Update failed: The calendar is not editable across accounts")
        let p = clonedAs("SOLO-NEW")
        let out = try await Edit.perform(id: 50, list: "Home", json: false, store: s, writer: m, private: p)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Moved #50 -> #93\nList: Home\nSubtasks: 0\n")
        #expect(p.calls == [.cloneReminderTree(id: "SOLO", listId: "CK-H", childIds: [])])
        #expect(m.calls.contains(.delete(id: "SOLO")))
    }

    @Test func unrelatedUpdateFailureIsNotRetriedAsAClone() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.updateError = WriteError("Update failed: Reminder not found for id: SOLO")
        let p = clonedAs("SOLO-NEW")
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 50, list: "Home", json: false, store: s, writer: m, private: p)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Update failed: Reminder not found for id: SOLO\n")
        #expect(p.calls.isEmpty)
    }

    // MARK: - Rejection classification

    @Test func boundaryRejectionsAreRecognized() {
        #expect(ListMove.failureAllowsCloneDelete("Update failed: calendar is in a different account"))
        #expect(ListMove.failureAllowsCloneDelete("Save failed: the container is not writable"))
        #expect(!ListMove.failureAllowsCloneDelete("Update failed: Reminder not found"))
        #expect(!ListMove.failureAllowsCloneDelete("Update failed: Reminders access not granted"))
        #expect(!ListMove.failureAllowsCloneDelete("List not found: Home"))
    }
}
