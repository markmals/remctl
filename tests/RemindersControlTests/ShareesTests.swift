import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct ShareesTests {
    /// The shared-list owner's sharee CKID. The list stores it as a UUID BLOB; the
    /// sharee row stores the TEXT form — deliberately lowercased here to exercise the
    /// case-insensitive ckid matching (upstream aba7cf5 fix).
    static let ownerUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0001")!

    private static func uuidBlobHex(_ uuid: UUID) -> String {
        let u = uuid.uuid
        let bytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                              u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// A shared list 'Family' (pk 5) with two sharees: the owner (pk 100, lowercase text
    /// ckid) and 'Zelda Fitzgerald' (pk 101, address mailto).
    private func sharedListFixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZSHAREDOWNERIDENTIFIER)
              VALUES (5,3,'Family',0,'CK-FAM',X'\(Self.uuidBlobHex(Self.ownerUUID))');
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZLIST,ZCKIDENTIFIER,ZDISPLAYNAME,ZSTATUS,ZACCESSLEVEL)
              VALUES (100,36,0,5,'\(Self.ownerUUID.uuidString.lowercased())','Me Myself',2,2);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZMARKEDFORDELETION,ZLIST,ZCKIDENTIFIER,ZFIRSTNAME,ZLASTNAME,ZADDRESS1,ZSTATUS,ZACCESSLEVEL)
              VALUES (101,36,0,5,'SHAREE-Z','Zelda','Fitzgerald','mailto:zelda@example.com',2,2);
            """)
        }
    }

    // ── query level ───────────────────────────────────────────────────────────

    @Test func shareesQueryReturnsOrderedRows() throws {
        let dir = try sharedListFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let rows = store.sharees(listPk: 5)
        #expect(rows.count == 2)
        #expect(rows[0].int("Z_PK") == 100)
        #expect(rows[1].string("ZADDRESS1") == "mailto:zelda@example.com")
        #expect(store.sharees(listPk: 999).isEmpty)
    }

    @Test func sharedOwnerCkidDecodesBlob() throws {
        let dir = try sharedListFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.listSharedOwnerCkid(listPk: 5) == Self.ownerUUID.uuidString)
        #expect(store.listSharedOwnerCkid(listPk: 999) == nil)
    }

    @Test func ckidEqIsCaseInsensitiveAndEmptySafe() {
        #expect(ckidEq("ABC-DEF", "abc-def"))
        #expect(ckidEq("same", "same"))
        #expect(!ckidEq("a", "b"))
        #expect(!ckidEq(nil, "a"))
        #expect(!ckidEq("a", nil))
        #expect(!ckidEq("", ""))
    }

    @Test func shareeDisplayNamePrecedence() {
        #expect(shareeDisplayName(DictRow(["ZDISPLAYNAME": "Disp", "ZFIRSTNAME": "F"])) == "Disp")
        #expect(shareeDisplayName(DictRow(["ZFIRSTNAME": "Zelda", "ZLASTNAME": "Fitzgerald"])) == "Zelda Fitzgerald")
        #expect(shareeDisplayName(DictRow(["ZLASTNAME": "Fitzgerald"])) == "Fitzgerald")
        #expect(shareeDisplayName(DictRow(["ZADDRESS1": "mailto:z@e.com"])) == "mailto:z@e.com")
        #expect(shareeDisplayName(DictRow([:])) == "")
    }

    @Test func shareeToDictMarksCurrentUserCaseInsensitively() throws {
        let dir = try sharedListFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let owner = store.listSharedOwnerCkid(listPk: 5)   // uppercase from blob
        let rows = store.sharees(listPk: 5)
        let me = shareeToDict(rows[0], currentUserCkid: owner)
        #expect(me.contains { $0.0 == "currentUser" && $0.1 == .bool(true) })
        let zelda = shareeToDict(rows[1], currentUserCkid: owner)
        #expect(!zelda.contains { $0.0 == "currentUser" })
        #expect(zelda.contains { $0.0 == "name" && $0.1 == .string("Zelda Fitzgerald") })
        #expect(zelda.contains { $0.0 == "address" && $0.1 == .string("mailto:zelda@example.com") })
    }

    // ── command level ─────────────────────────────────────────────────────────

    @Test func shareesCommandJSON() throws {
        let dir = try sharedListFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sharees", "Family", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect((d?["currentUserSharee"] as? String) == Self.ownerUUID.uuidString)
        let list = d?["list"] as? [String: Any]
        #expect((list?["title"] as? String) == "Family")
        let sharees = d?["sharees"] as? [[String: Any]]
        #expect(sharees?.count == 2)
        #expect((sharees?[0]["currentUser"] as? Bool) == true)
        #expect((sharees?[1]["name"] as? String) == "Zelda Fitzgerald")
    }

    @Test func shareesCommandHuman() throws {
        let dir = try sharedListFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sharees", "Family", "--no-color"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Sharees for Family:"))
        #expect(r.stdout.contains("- Me Myself (me)"))
        #expect(r.stdout.contains("- Zelda Fitzgerald mailto:zelda@example.com (id: 101)"))
        #expect(r.stdout.contains("\n2 sharees\n"))
    }

    @Test func shareesCommandNoSharees() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Solo',0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sharees", "Solo", "--no-color"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("No sharees"))
    }

    @Test func shareesCommandRequiresListTarget() throws {
        let dir = try sharedListFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["sharees"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("pass a list name or --list-id"))
    }
}
