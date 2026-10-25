import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `section-create`/`section-rename`/`section-delete` (upstream c0db904): every write targets a
/// section of one list, refuses name collisions before calling ReminderKit, and is reported only
/// once the store shows it.
@Suite struct SectionWriteTests {
    /// Projects (pk 1, CK-1) holds Inbox (S1) and Active (S2), displayed Active-first through the
    /// list's persisted section order. Writing (pk 2) is a list group.
    private func fixture() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            ALTER TABLE ZREMCDBASELIST ADD COLUMN ZSECTIONIDSORDERINGASDATA BLOB;
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZSECTIONIDSORDERINGASDATA)
              VALUES (1,3,'Projects','CK-1',0,'{"minimumSupportedVersion":20230430,"orderedIdentifiers":["S2","GONE","S1"]}');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP)
              VALUES (2,3,'Writing','CK-2',0,1);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (10,'Inbox',1,'S1',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (11,'Active',1,'S2',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (12,'Later',1,'S3',0);
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// Applies `sql` to the fixture, standing in for the save ReminderKit would have made.
    private func landing(_ dir: URL, _ sql: String) -> (MockPrivateWriter.Call) -> Void {
        { _ in
            let queue = try? DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path)
            try? queue?.write { try $0.execute(sql: sql) }
        }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - section-create

    @Test func createAppendsToThePersistedSectionOrderAndVerifies() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "created", fields: ["sectionId": .string("NEW-S")])
        p.onCall = landing(dir, "INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (13,'Research',1,'NEW-S',0)")
        let out = try await SectionCreate.perform(name: "Research", list: "Projects", listId: nil, json: true,
                                                  store: store, private: p, readback: .immediate)
        // The stale GONE entry drops out; Later, which the record does not mention yet, follows.
        #expect(p.calls == [.createSection(listId: "CK-1", name: "Research", existingSectionIds: ["S2", "S1", "S3"])])
        let payload = try json(out.stdout)
        #expect(payload["status"] as? String == "created")
        #expect(payload["sectionId"] as? String == "NEW-S")
        #expect(payload["listId"] as? Int == 1)
        #expect(payload["verified"] as? Bool == true)
    }

    @Test func createRefusesADuplicateNameBeforeWriting() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await WriteDispatch.perform(json: true) {
            try await SectionCreate.perform(name: "inbox", list: "Projects", listId: nil, json: true,
                                            store: store, private: p, readback: .immediate)
        }
        #expect(out.exitCode == 1)
        #expect(try json(out.stderr)["code"] as? String == "section_exists")
        #expect(p.calls.isEmpty)
    }

    @Test func createFailsWhenTheStoreNeverShowsTheSection() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "created", fields: ["sectionId": .string("NEW-S")])
        let out = await WriteDispatch.perform(json: false) {
            try await SectionCreate.perform(name: "Research", list: "Projects", listId: nil, json: false,
                                            store: store, private: p, readback: .immediate)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: ReminderKit reported success, but the new section could not be verified.\n")
    }

    @Test func createRefusesAListGroupWithAStructuredCode() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await WriteDispatch.perform(json: true) {
            try await SectionCreate.perform(name: "Research", list: "Writing", listId: nil, json: true,
                                            store: store, private: p, readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "list_is_group")
        #expect(p.calls.isEmpty)
    }

    @Test func createReportsTheHelperMessageWhenReminderKitRefuses() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "error", message: "ReminderKit section context unavailable")
        let out = await WriteDispatch.perform(json: true) {
            try await SectionCreate.perform(name: "Research", list: "Projects", listId: nil, json: true,
                                            store: store, private: p, readback: .immediate)
        }
        let payload = try json(out.stderr)
        #expect(payload["code"] as? String == "private_write_failed")
        #expect(payload["message"] as? String == "ReminderKit section context unavailable")
    }

    // MARK: - section-rename

    @Test func renameRefusesANameAnotherSectionUses() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = await WriteDispatch.perform(json: false) {
            try await SectionRename.perform(name: "Inbox", sectionId: nil, newName: "ACTIVE", list: "Projects",
                                            listId: nil, json: false, store: store, private: p, readback: .immediate)
        }
        #expect(out.stderr == "Error: another section in 'Projects' is already named 'ACTIVE'.\n")
        #expect(p.calls.isEmpty)
    }

    @Test func renameChangingOnlyCaseIsAllowedAndVerified() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.onCall = landing(dir, "UPDATE ZREMCDBASESECTION SET ZDISPLAYNAME = 'INBOX' WHERE Z_PK = 10")
        let out = try await SectionRename.perform(name: "Inbox", sectionId: nil, newName: "INBOX", list: "Projects",
                                                  listId: nil, json: false, store: store, private: p, readback: .immediate)
        #expect(p.calls == [.renameSection(sectionId: "S1", name: "INBOX")])
        #expect(out.stdout == "Renamed section: Inbox -> INBOX in Projects\n")
    }

    @Test func renameIsUnverifiedWhileTheOldNameRemains() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = await WriteDispatch.perform(json: true) {
            try await SectionRename.perform(name: nil, sectionId: "s2", newName: "Doing", list: nil, listId: 1,
                                            json: true, store: store, private: MockPrivateWriter(), readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "section_write_unverified")
    }

    // MARK: - section-delete

    @Test func deleteNeedsForceUnderJSON() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        let out = try await SectionDelete.perform(name: "Inbox", sectionId: nil, list: "Projects", listId: nil,
                                                  force: false, json: true, store: store, private: p,
                                                  confirm: .unexpected, readback: .immediate)
        let payload = try json(out.stderr)
        #expect(payload["code"] as? String == "confirmation_required")
        #expect(payload["id"] as? String == "S1")
        #expect(p.calls.isEmpty)
    }

    @Test func deleteBySectionIdNamesTheSectionAndVerifiesItIsGone() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "deleted")
        p.onCall = landing(dir, "UPDATE ZREMCDBASESECTION SET ZMARKEDFORDELETION = 1 WHERE Z_PK = 11")
        let prompted = Prompted()
        let out = try await SectionDelete.perform(name: nil, sectionId: "S2", list: "Projects", listId: nil,
                                                  force: false, json: false, store: store, private: p,
                                                  confirm: .recording({ prompted.value = $0 }), readback: .immediate)
        #expect(prompted.value == "Delete section 'Active' in 'Projects'? Its reminders move to the list's default area. [y/N] ")
        #expect(p.calls == [.deleteSection(sectionId: "S2")])
        #expect(out.stdout == "Deleted section: Active in Projects\n")
    }

    @Test func deleteIsUnverifiedWhileTheSectionIsStillLive() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        p.result = PrivateResult(status: "deleted")
        let out = await WriteDispatch.perform(json: true) {
            try await SectionDelete.perform(name: "Active", sectionId: nil, list: "Projects", listId: nil,
                                            force: true, json: true, store: store, private: p,
                                            confirm: .unexpected, readback: .immediate)
        }
        #expect(try json(out.stderr)["code"] as? String == "section_write_unverified")
    }

    // MARK: - section order

    @Test func sectionOrderFallsBackToIdOrderWithoutARecord() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (1,3,'Projects','CK-1',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (11,'B',1,'S2',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (10,'A',1,'S1',0);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (12,'C',1,'S3',1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try RemindersStore.open(storeDir: dir).sectionOrder(listPk: 1) == ["S1", "S2"])
    }

    @Test func newSectionOnEditAppendsToThePersistedOrder() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "REM-1", url: nil, tags: [], section: nil, sectionId: nil, newSection: "Research",
            flagged: nil, urgent: nil, earlyReminder: nil, store: store, listPk: 1, writer: MockWriter(), private: p)
        #expect(p.calls == [.addSectionAndAssign(id: "REM-1", name: "Research", existingSectionIds: ["S2", "S1", "S3"])])
    }
}
