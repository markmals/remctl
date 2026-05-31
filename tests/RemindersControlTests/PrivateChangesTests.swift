import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// PrivateChangesTests — the P12 private-metadata fan-out (PrivateChanges.apply).
//
// Verifies emission ORDER (matching apply_private_changes:3003), section pre-resolution,
// flag/flagged collapse, and the early-reminder existing-identifier injection.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct PrivateChangesTests {

    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try build(db)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A list (pk 10, ckid CK-W) with a section "Errands" (ckid SEC-1) and a reminder
    /// (ckid R1) carrying one early-reminder delta-alert with identifier "EXIST-1".
    private func withListSectionReminder() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDBASESECTION (Z_PK,Z_ENT,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (1,5,'Errands',10,'SEC-1',0)")
            let blob = #"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":0,"dueDateDeltaCount":-15,"identifier":"EXIST-1"}]}"#
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATEDELTAALERTSDATA) VALUES (42,'T',10,1,0,'R1',?)", arguments: [blob])
        }
    }

    @Test func emissionOrderUrlTagsSectionUrgentEarly() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let results = try await PrivateChanges.apply(
            reminderCkid: "R1",
            url: "https://x", tags: ["work", "home"],
            section: "Errands", sectionId: nil, newSection: nil,
            flagged: nil, urgent: true,
            earlyReminder: .set(unit: 0, count: -15, existingIdentifiers: []),
            store: s, listPk: 10, writer: MockWriter(), private: mp)
        // Order: addPrivateMetadata, assignSection, setUrgent, setEarlyReminder.
        #expect(mp.calls == [
            .addPrivateMetadata(id: "R1", urls: ["https://x"], tags: ["work", "home"]),
            .assignSection(id: "R1", sectionId: "SEC-1"),
            .setUrgent(id: "R1", urgent: true),
            .setEarlyReminder(id: "R1", spec: .set(unit: 0, count: -15, existingIdentifiers: ["EXIST-1"])),
        ])
        #expect(results.count == 4)
    }

    @Test func sectionResolvesToCkidViaFixture() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: "Errands", sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: 10, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.assignSection(id: "R1", sectionId: "SEC-1")])
    }

    @Test func newSectionEmitsAddSectionAndAssign() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: "Inbox",
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: 10, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.addSectionAndAssign(id: "R1", name: "Inbox")])
    }

    @Test func flaggedCollapsedToSetFlagged() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: true, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.setFlagged(id: "R1", flagged: true)])
    }

    @Test func earlyReminderInjectsExistingIdentifiers() async throws {
        // The parsed spec carries [] for identifiers; apply() replaces it with the reminder's
        // existing delta-alert identifiers from the store (early_reminder_identifiers_for_reminder).
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil,
            earlyReminder: .clear(existingIdentifiers: []),
            store: s, listPk: nil, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.setEarlyReminder(id: "R1", spec: .clear(existingIdentifiers: ["EXIST-1"]))])
    }

    @Test func earlyReminderNoExistingAlertsEmptyIdentifiers() async throws {
        // A reminder with no delta-alert blob → empty existingIdentifiers.
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (1,'T',1,0,'R9')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R9", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil,
            earlyReminder: .set(unit: 0, count: -15, existingIdentifiers: []),
            store: s, listPk: nil, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.setEarlyReminder(id: "R9", spec: .set(unit: 0, count: -15, existingIdentifiers: []))])
    }

    @Test func noFieldsNoCalls() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let results = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: MockWriter(), private: mp)
        #expect(mp.calls.isEmpty)
        #expect(results.isEmpty)
    }

    @Test func sectionNotFoundThrows() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        await #expect(throws: CLIError.self) {
            _ = try await PrivateChanges.apply(
                reminderCkid: "R1", url: nil, tags: [],
                section: "Nonexistent", sectionId: nil, newSection: nil,
                flagged: nil, urgent: nil, earlyReminder: nil,
                store: s, listPk: 10, writer: MockWriter(), private: mp)
        }
    }

    // ── P13: subtask fan-out + image attachments ────────────────────────────

    /// A child-entries PrivateResult mirroring the ObjC add_subtasks result shape:
    /// fields["subtasks"] = [{id,title,url}, …].
    private func childResult(_ children: [(id: String, title: String)]) -> PrivateResult {
        let arr = JSONValue.array(children.map {
            .object([("id", .string($0.id)), ("title", .string($0.title)), ("url", .string("rem://\($0.id)"))])
        })
        return PrivateResult(status: "updated", fields: ["subtasks": arr])
    }

    @Test func subtaskBareTitle() async throws {
        // A bare-title subtask: addSubtasks only — no child public/private writes.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult([(id: "C1", title: "Buy milk")])
        let mw = MockWriter()
        let results = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            subtasks: [SubtaskSpec(title: "Buy milk")], images: [],
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: mw, private: mp)
        #expect(mp.calls == [.addSubtasks(id: "R1", subtasks: [SubtaskSpec(title: "Buy milk")])])
        #expect(mw.calls.isEmpty)               // no child public bridge update
        #expect(results.count == 1)             // just the add_subtasks result
    }

    @Test func subtaskWithPublicFields() async throws {
        // notes/due/priority route to the EventKit bridge (writer.update) for the created child.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult([(id: "C1", title: "x")])
        let mw = MockWriter()
        let spec = SubtaskSpec(title: "x", notes: "n", due: "tomorrow", priority: "high")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            subtasks: [spec], images: [],
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: mw, private: mp,
            now: now, calendar: .current)
        // Private writer: only the add_subtasks call (no private child fields on this spec).
        #expect(mp.calls == [.addSubtasks(id: "R1", subtasks: [spec])])
        // Public writer: exactly one child update with notes/due/priority on "C1".
        #expect(mw.calls.count == 1)
        guard case let .update(id, w) = mw.calls[0] else { Issue.record("expected child update"); return }
        #expect(id == "C1")
        #expect(w.notes == "n")
        #expect(w.priority == 1)          // high → 1
        if case .set = w.due {} else { Issue.record("expected child due .set") }
    }

    @Test func subtaskWithPrivateChildFields() async throws {
        // flagged/urgent/tags route to the private writer on the created child "C1".
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult([(id: "C1", title: "x")])
        let mw = MockWriter()
        let spec = SubtaskSpec(title: "x", tags: ["a", "b"], flagged: true, urgent: true)
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            subtasks: [spec], images: [],
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: mw, private: mp)
        // Order: add_subtasks, then child add_private_metadata (tags), set_flagged, set_urgent.
        #expect(mp.calls == [
            .addSubtasks(id: "R1", subtasks: [spec]),
            .addPrivateMetadata(id: "C1", urls: [], tags: ["a", "b"]),
            .setFlagged(id: "C1", flagged: true),
            .setUrgent(id: "C1", urgent: true),
        ])
        #expect(mw.calls.isEmpty)   // no public bridge fields
    }

    @Test func subtaskChildMetadataBeforeBridge() async throws {
        // For a child with BOTH private (flagged) and public (notes) fields, the private metadata
        // is emitted into the results array BEFORE the public bridge update (apply_private_changes).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult([(id: "C1", title: "x")])
        let mw = MockWriter()
        let spec = SubtaskSpec(title: "x", notes: "n", flagged: true)
        let results = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            subtasks: [spec], images: [],
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: mw, private: mp)
        // results: [add_subtasks, child set_flagged, child bridge update]
        #expect(results.count == 3)
        #expect(results[0].fields["subtasks"] != nil)                 // the add_subtasks result
        #expect(results[2].fields["action"] == .string("update"))      // the bridge update result, last
        // The private set_flagged call precedes the public update call (cross-writer ordering).
        #expect(mp.calls == [.addSubtasks(id: "R1", subtasks: [spec]), .setFlagged(id: "C1", flagged: true)])
        #expect(mw.calls.count == 1)
    }

    @Test func imageAttachments() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let images = ["/tmp/a.png", "/tmp/b.png"]
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            subtasks: [], images: images,
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.addAttachments(id: "R1", images: images)])
    }

    @Test func subtaskBeforeImageBeforeFlag() async throws {
        // Emission order: add_subtasks (4) → add_attachments (5) → set_flagged (6).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult([(id: "C1", title: "t")])
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            subtasks: [SubtaskSpec(title: "t")], images: ["/tmp/a.png"],
            flagged: true, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, writer: MockWriter(), private: mp)
        #expect(mp.calls == [
            .addSubtasks(id: "R1", subtasks: [SubtaskSpec(title: "t")]),
            .addAttachments(id: "R1", images: ["/tmp/a.png"]),
            .setFlagged(id: "R1", flagged: true),
        ])
    }
}
