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
            store: s, listPk: 10, private: mp)
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
            store: s, listPk: 10, private: mp)
        #expect(mp.calls == [.assignSection(id: "R1", sectionId: "SEC-1")])
    }

    @Test func newSectionEmitsAddSectionAndAssign() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: "Inbox",
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: 10, private: mp)
        #expect(mp.calls == [.addSectionAndAssign(id: "R1", name: "Inbox")])
    }

    @Test func flaggedCollapsedToSetFlagged() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: true, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, private: mp)
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
            store: s, listPk: nil, private: mp)
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
            store: s, listPk: nil, private: mp)
        #expect(mp.calls == [.setEarlyReminder(id: "R9", spec: .set(unit: 0, count: -15, existingIdentifiers: []))])
    }

    @Test func noFieldsNoCalls() async throws {
        let (s, dir) = try withListSectionReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let results = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil, earlyReminder: nil,
            store: s, listPk: nil, private: mp)
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
                store: s, listPk: 10, private: mp)
        }
    }
}
