import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// `list-info` (port of upstream b8b601c): one list's `lists --json` object plus the section ids
/// `--section-id` needs and the sharees `--assign` needs.
@Suite struct ListInfoTests {
    /// The shared-list owner's sharee CKID; the list stores it as a UUID BLOB.
    static let ownerUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0002")!

    private static func uuidBlobHex(_ uuid: UUID) -> String {
        let u = uuid.uuid
        let bytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                              u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Shopping (pk 1, shared, two sections sharing the name 'Produce' plus a deleted one),
    /// Work (pk 2, one section, unshared), '🗓️ Weekly 513' (pk 3, normalized-name target),
    /// the list group Writing (pk 4) with its child Essays (pk 5), Solo (pk 6, nothing at all)
    /// and Groceries (pk 7).
    private func fixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZSHAREDOWNERIDENTIFIER)
              VALUES (1,3,'Shopping','L1',0,X'\(Self.uuidBlobHex(Self.ownerUUID))');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZISGROUP,ZPARENTLIST,ZSHOULDCATEGORIZEGROCERYITEMS)
              VALUES (2,3,'Work','L2',0,NULL,NULL,NULL),
                     (3,3,'🗓️ Weekly 513','L3',0,NULL,NULL,NULL),
                     (4,3,'Writing','L4',0,1,NULL,NULL),
                     (5,3,'Essays','L5',0,NULL,4,NULL),
                     (6,3,'Solo','L6',0,NULL,NULL,NULL),
                     (7,3,'Groceries','L7',0,NULL,NULL,1);
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES
              (1,'Produce',1,'SEC-A',0),
              (2,'Produce',1,'SEC-B',0),
              (3,'Drafts',2,'SEC-C',0),
              (4,'Deleted',1,'SEC-D',1);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZLIST,ZCKIDENTIFIER,ZDISPLAYNAME,ZADDRESS1,ZSTATUS,ZACCESSLEVEL)
              VALUES (40,36,0,1,'SHAREE-1','Alex','alex@example.com',2,2),
                     (41,36,0,1,'\(Self.ownerUUID.uuidString.lowercased())','Me Myself',NULL,2,2);
            """)
        }
    }

    private func report(_ dir: URL, name: String? = nil, listId: Int? = nil) throws -> ListInfoReport {
        try listInfoReport(store: try RemindersStore.open(storeDir: dir), name: name, listId: listId)
    }

    private func expectCLIError(_ expected: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected CLIError: \(expected)")
        } catch let error as CLIError {
            #expect(error.message == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // ── payload ───────────────────────────────────────────────────────────────

    @Test func duplicateSectionNamesKeepDistinctIdsAndOrder() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let sections = try report(dir, name: "Shopping").sections
        #expect(sections.map { $0.name } == ["Produce", "Produce"])
        #expect(sections.map { $0.id } == ["SEC-A", "SEC-B"])
    }

    @Test func sharedListListsShareesWithAddress() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = try report(dir, name: "Shopping").json.serialized(indent: nil, ensureAscii: false)
        #expect(json.contains("\"shared\": true"))
        #expect(json.contains("\"address\": \"alex@example.com\""))
        #expect(json.contains("\"currentUser\": true"))
        let sharees = try report(dir, name: "Shopping").sharees
        #expect(sharees.map { $0.id } == [40, 41])
        #expect(sharees.map { $0.isCurrentUser } == [false, true])
    }

    /// The whole `--list-id` payload, in key order: `listToDict` first, then sections/sharees/shared.
    @Test func listIdPayloadKeepsListJSONShapeAndReportsUnshared() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = try report(dir, listId: 2).json.serialized(indent: nil, ensureAscii: false)
        #expect(json == """
        {"id": 2, "title": "Work", "listType": "standard", "isGroup": false, "isGroceries": false, \
        "objectUUID": "L2", "pinned": false, "sections": [{"id": "SEC-C", "name": "Drafts"}], \
        "sharees": [], "shared": false}
        """)
    }

    @Test func groceriesListReportsItsType() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try report(dir, name: "Groceries").listType == "groceries")
    }

    // ── resolution ────────────────────────────────────────────────────────────

    @Test func exactNameOmitsResolvedFrom() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try report(dir, name: "Shopping").resolvedFrom == nil)
        #expect(try !report(dir, name: "Shopping").json
            .serialized(indent: nil, ensureAscii: false).contains("resolvedFrom"))
    }

    @Test func caseInsensitiveNameAddsResolvedFrom() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let found = try report(dir, name: "shopping")
        #expect(found.id == 1)
        #expect(found.resolvedFrom == "shopping")
        #expect(found.json.serialized(indent: nil, ensureAscii: false)
            .contains("\"resolvedFrom\": \"shopping\", \"sections\""))
    }

    @Test func normalizedNameAddsResolvedFrom() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let found = try report(dir, name: "Weekly 513")
        #expect(found.id == 3)
        #expect(found.title == "🗓️ Weekly 513")
        #expect(found.resolvedFrom == "Weekly 513")
    }

    @Test func listIdOmitsResolvedFrom() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try report(dir, listId: 1).resolvedFrom == nil)
    }

    @Test func listGroupIsRefusedByNameAndById() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let message = "'Writing' is a Reminders list group, not a writable list. "
            + "Use one of its child lists: Essays (id 5)"
        expectCLIError(message) { _ = try report(dir, name: "Writing") }
        expectCLIError(message) { _ = try report(dir, listId: 4) }
    }

    @Test func exactlyOneTargetIsRequired() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        expectCLIError("pass a list name or --list-id.") { _ = try report(dir) }
        expectCLIError("pass either a list name or --list-id, not both.") {
            _ = try report(dir, name: "Shopping", listId: 1)
        }
        expectCLIError("list not found: Nope") { _ = try report(dir, name: "Nope") }
    }

    // ── human output ──────────────────────────────────────────────────────────

    @Test func humanOutputForSharedList() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try report(dir, name: "Shopping").lines(ansi: Ansi(enabled: false)) == [
            "Shopping (id: 1)",
            "Type: standard",
            "Sections:",
            "  - Produce (SEC-A)",
            "  - Produce (SEC-B)",
            "Shared with:",
            "  - Alex (id: 40)",
            "  - Me Myself (me) (id: 41)",
        ])
    }

    @Test func humanOutputForUnsharedListAndEmptyList() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try report(dir, listId: 2).lines(ansi: Ansi(enabled: false)) == [
            "Work (id: 2)",
            "Type: standard",
            "Sections:",
            "  - Drafts (SEC-C)",
            "Not shared",
        ])
        #expect(try report(dir, name: "Solo").lines(ansi: Ansi(enabled: false)) == [
            "Solo (id: 6)",
            "Type: standard",
            "Sections: none",
            "Not shared",
        ])
    }

    @Test func humanOutputColorsTitleAndIds() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let lines = try report(dir, name: "Solo").lines(ansi: Ansi(enabled: true))
        #expect(lines[0] == "\u{1B}[1mSolo\u{1B}[0m \u{1B}[2m(id: 6)\u{1B}[0m")
    }

    // ── command ───────────────────────────────────────────────────────────────

    @Test func listInfoCommandJSON() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["list-info", "Shopping", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect((d?["id"] as? Int) == 1)
        #expect((d?["title"] as? String) == "Shopping")
        #expect((d?["shared"] as? Bool) == true)
        let sections = d?["sections"] as? [[String: Any]]
        #expect(sections?.map { $0["id"] as? String } == ["SEC-A", "SEC-B"])
        let sharees = d?["sharees"] as? [[String: Any]]
        #expect((sharees?.first?["address"] as? String) == "alex@example.com")
    }

    @Test func listInfoCommandHuman() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["list-info", "--list-id", "2"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "Work (id: 2)\nType: standard\nSections:\n  - Drafts (SEC-C)\nNot shared\n")
    }

    @Test func listInfoCommandRefusesGroupAndMissingTarget() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let group = try CLIRunner.run(["list-info", "Writing", "--json"], storeDir: dir)
        #expect(group.exit == 1)
        #expect(group.stderr.contains("Error: 'Writing' is a Reminders list group, not a writable list."))
        #expect(group.stdout.isEmpty)
        let bare = try CLIRunner.run(["list-info"], storeDir: dir)
        #expect(bare.exit == 1)
        #expect(bare.stderr.contains("Error: pass a list name or --list-id."))
    }
}
