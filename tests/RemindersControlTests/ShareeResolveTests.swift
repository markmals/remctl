import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// ShareeResolveTests — resolve_sharee_or_die / resolve_assignment_originator_or_die
// (upstream 683c362) with the 03a2920 guardrail matrix and the aba7cf5
// case-insensitive CKID fix.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct ShareeResolveTests {
    static let ownerUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0001")!

    private static func uuidBlobHex(_ uuid: UUID) -> String {
        let u = uuid.uuid
        let bytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                              u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Shared list 'Family' (pk 5): owner (pk 100, lowercase ckid text), Zelda
    /// Fitzgerald (pk 101, mailto address) and Scott Fitzgerald (pk 102, tel address).
    /// Reminder pk 42 (ckid R1) lives in it. List 'Solo' (pk 6) has no sharees.
    private func fixture() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZSHAREDOWNERIDENTIFIER)
              VALUES (5,3,'Family',0,'CK-FAM',X'\(Self.uuidBlobHex(Self.ownerUUID))');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (6,3,'Solo',0,'CK-SOLO');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZLIST,ZCKIDENTIFIER,ZDISPLAYNAME)
              VALUES (100,36,0,5,'\(Self.ownerUUID.uuidString.lowercased())','Me Myself');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZLIST,ZCKIDENTIFIER,ZFIRSTNAME,ZLASTNAME,ZADDRESS1)
              VALUES (101,36,0,5,'SHAREE-Z','Zelda','Fitzgerald','mailto:zelda@example.com');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZLIST,ZCKIDENTIFIER,ZFIRSTNAME,ZLASTNAME,ZADDRESS1)
              VALUES (102,36,0,5,'SHAREE-S','Scott','Fitzgerald','tel:+15551234567');
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'T',5,1,0,'R1');
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    private func expectCLIError(_ fragment: String, _ body: () throws -> Void,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try body()
            Issue.record("expected CLIError containing '\(fragment)'", sourceLocation: sourceLocation)
        } catch let e as CLIError {
            #expect(e.message.contains(fragment), "got: \(e.message)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected CLIError, got \(error)", sourceLocation: sourceLocation)
        }
    }

    // ── resolveSharee ─────────────────────────────────────────────────────────

    @Test func unsharedListHasNoSharees() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        expectCLIError("target list has no sharees; assignment requires a shared list.") {
            _ = try resolveSharee(store: s, listPk: 6, value: "anyone")
        }
    }

    @Test func emptyValueRejected() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        expectCLIError("--assign requires a name, email, phone number, or sharee ID.") {
            _ = try resolveSharee(store: s, listPk: 5, value: "   ")
        }
    }

    @Test func meResolvesOwnerCaseInsensitively() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // Owner blob decodes UPPERCASE; the sharee row's text ckid is lowercase.
        let me = try resolveSharee(store: s, listPk: 5, value: "me")
        #expect(me.int("Z_PK") == 100)
        let myself = try resolveSharee(store: s, listPk: 5, value: "MYSELF")
        #expect(myself.int("Z_PK") == 100)
    }

    @Test func exactFullNameMatch() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try resolveSharee(store: s, listPk: 5, value: "Zelda Fitzgerald").int("Z_PK") == 101)
    }

    @Test func emailTailMatch() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try resolveSharee(store: s, listPk: 5, value: "zelda@example.com").int("Z_PK") == 101)
    }

    @Test func numericPkMatch() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try resolveSharee(store: s, listPk: 5, value: "102").int("Z_PK") == 102)
    }

    @Test func containsMatchFallsBack() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try resolveSharee(store: s, listPk: 5, value: "zelda").int("Z_PK") == 101)
    }

    @Test func ambiguousMatchListsOptions() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        expectCLIError("multiple sharees match") {
            _ = try resolveSharee(store: s, listPk: 5, value: "fitzgerald")
        }
    }

    @Test func noMatchListsAvailable() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        expectCLIError("no sharee matching") {
            _ = try resolveSharee(store: s, listPk: 5, value: "bob")
        }
    }

    // ── resolveAssignmentOriginator ───────────────────────────────────────────

    @Test func originatorIsOwnerSharee() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try resolveAssignmentOriginator(store: s, listPk: 5).int("Z_PK") == 100)
    }

    @Test func originatorFailsWithoutOwner() throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        expectCLIError("could not identify the current-user sharee for assignment originator.") {
            _ = try resolveAssignmentOriginator(store: s, listPk: 6)
        }
    }

    // ── PrivateChanges fan-out ────────────────────────────────────────────────

    @Test func assignEmitsAssignShareeWithOriginator() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let results = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil, earlyReminder: nil,
            assign: "Zelda", unassign: false,
            store: s, listPk: 5, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.assignSharee(id: "R1", assigneeId: "SHAREE-Z",
                                           originatorId: Self.ownerUUID.uuidString.lowercased())])
        #expect(results.count == 1)
    }

    @Test func unassignEmitsClearAssignment() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        _ = try await PrivateChanges.apply(
            reminderCkid: "R1", url: nil, tags: [],
            section: nil, sectionId: nil, newSection: nil,
            flagged: nil, urgent: nil, earlyReminder: nil,
            assign: nil, unassign: true,
            store: s, listPk: 5, writer: MockWriter(), private: mp)
        #expect(mp.calls == [.clearAssignment(id: "R1")])
    }

    @Test func assignWithoutListTargetFails() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        await #expect(throws: CLIError.self) {
            _ = try await PrivateChanges.apply(
                reminderCkid: "R1", url: nil, tags: [],
                section: nil, sectionId: nil, newSection: nil,
                flagged: nil, urgent: nil, earlyReminder: nil,
                assign: "Zelda", unassign: false,
                store: s, listPk: nil, writer: MockWriter(), private: mp)
        }
        #expect(mp.calls.isEmpty)
    }

    // ── command level ─────────────────────────────────────────────────────────

    @Test func addRejectsAssignPlusUnassign() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", list: "Family", assign: "Zelda", unassign: true,
                                  json: false, store: s, writer: MockWriter(), private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("pass either --assign or --unassign, not both."))
    }

    @Test func addAssignRoutesPrivate() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "R1"
        let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "Chores", list: "Family", assign: "me",
                                        json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.assignSharee(id: "R1", assigneeId: Self.ownerUUID.uuidString.lowercased(),
                                           originatorId: Self.ownerUUID.uuidString.lowercased())])
    }

    @Test func editUnassignUsesReminderListPk() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, unassign: true, json: false,
                                         store: s, writer: MockWriter(), private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.clearAssignment(id: "R1")])
    }

    @Test func editAssignResolvesAgainstReminderList() async throws {
        let (s, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, assign: "scott", json: false,
                                         store: s, writer: MockWriter(), private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.assignSharee(id: "R1", assigneeId: "SHAREE-S",
                                           originatorId: Self.ownerUUID.uuidString.lowercased())])
    }
}
