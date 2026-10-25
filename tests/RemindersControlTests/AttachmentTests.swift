import Testing
import Foundation
import CryptoKit
import GRDB
@testable import RemindersControl

/// A Reminders group container: `Stores/Data-test.sqlite` plus the sibling `Files/` tree
/// attachment blobs live in.
struct AttachmentContainer {
    let root: URL
    let storeDir: URL

    static func make(_ build: (Database) throws -> Void) throws -> AttachmentContainer {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-att-\(UUID().uuidString)")
        let storeDir = root.appendingPathComponent("Stores")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: storeDir.appendingPathComponent("Data-test.sqlite").path)
        try queue.write { try build($0) }
        return AttachmentContainer(root: root, storeDir: storeDir)
    }

    /// Writes `content` as `Files/<account>/Attachments/<sha512><ext>` and returns its sum.
    @discardableResult
    func writeBlob(_ content: Data, ext: String, account: String = "Account-test",
                   sha: String? = nil) throws -> String {
        let dir = root.appendingPathComponent("Files/\(account)/Attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sum = sha ?? sha512Hex(content)
        try content.write(to: dir.appendingPathComponent(sum + ext))
        return sum
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

func sha512Hex(_ data: Data) -> String {
    SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite struct AttachmentResolverTests {
    let blob = Data("pretend this is a png".utf8)

    @Test func candidateExtensionsPreferFilenameThenUTIThenFallbacks() {
        #expect(attachmentCandidateExtensions(filename: "photo.png", uti: "public.jpeg")
                == [".png", ".jpg", ".jpeg", ".heic"])
        #expect(attachmentCandidateExtensions(filename: "scan.BMP", uti: "com.example.unknown")
                == [".bmp", ".png", ".jpg", ".jpeg", ".heic"])
        #expect(attachmentCandidateExtensions(filename: nil, uti: "com.adobe.pdf")
                == [".pdf", ".png", ".jpg", ".jpeg", ".heic"])
        #expect(attachmentCandidateExtensions(filename: nil, uti: nil)
                == [".png", ".jpg", ".jpeg", ".heic"])
    }

    @Test func onlyA128HexSumIsUsable() {
        let sum = sha512Hex(blob)
        #expect(normalizedAttachmentSHA(sum.uppercased()) == sum)
        #expect(normalizedAttachmentSHA("  \(sum)  ") == sum)
        #expect(normalizedAttachmentSHA(nil) == nil)
        #expect(normalizedAttachmentSHA("not-a-sha") == nil)
        #expect(normalizedAttachmentSHA(String(sum.dropLast())) == nil)
        #expect(normalizedAttachmentSHA(String(repeating: "z", count: 128)) == nil)
    }

    @Test func resolvesOnlyWhenTheFileHashesToTheStoredSum() throws {
        let c = try AttachmentContainer.make { _ in }
        defer { c.cleanUp() }
        let sum = try c.writeBlob(blob, ext: ".png")
        let resolver = AttachmentFileResolver(storeDir: c.storeDir)
        let path = resolver.resolve(sha512: sum, filename: "photo.png", uti: "public.png")
        #expect(path?.hasSuffix("Files/Account-test/Attachments/\(sum).png") == true)
    }

    @Test func rejectsTamperedBytes() throws {
        let c = try AttachmentContainer.make { _ in }
        defer { c.cleanUp() }
        let sum = sha512Hex(blob)
        try c.writeBlob(Data("tampered bytes, not the original".utf8), ext: ".png", sha: sum)
        let resolver = AttachmentFileResolver(storeDir: c.storeDir)
        #expect(resolver.resolve(sha512: sum, filename: "photo.png", uti: "public.png") == nil)
    }

    @Test func findsTheBlobInAnyAccountDirectory() throws {
        let c = try AttachmentContainer.make { _ in }
        defer { c.cleanUp() }
        try FileManager.default.createDirectory(
            at: c.root.appendingPathComponent("Files/Account-A/Attachments"), withIntermediateDirectories: true)
        let sum = try c.writeBlob(blob, ext: ".png", account: "Account-B")
        let resolver = AttachmentFileResolver(storeDir: c.storeDir)
        #expect(resolver.resolve(sha512: sum, filename: "photo.png", uti: "public.png")?.contains("Account-B") == true)
    }

    @Test func oversizeFilesAreNeverHashed() throws {
        let c = try AttachmentContainer.make { _ in }
        defer { c.cleanUp() }
        let sum = sha512Hex(blob)
        let dir = c.root.appendingPathComponent("Files/Account-test/Attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appendingPathComponent("\(sum).png")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AttachmentFileResolver.maxHashedBytes + 1))
        try handle.close()

        var hashed = 0
        let resolver = AttachmentFileResolver(storeDir: c.storeDir) { _ in hashed += 1; return sum }
        #expect(resolver.resolve(sha512: sum, filename: "photo.png", uti: "public.png") == nil)
        #expect(hashed == 0)
    }

    @Test func repeatedLookupsHashTheFileOnce() throws {
        let c = try AttachmentContainer.make { _ in }
        defer { c.cleanUp() }
        let sum = try c.writeBlob(blob, ext: ".png")
        var hashed = 0
        let resolver = AttachmentFileResolver(storeDir: c.storeDir) { url in
            hashed += 1
            return AttachmentFileResolver.sha512Hex(of: url)
        }
        let first = resolver.resolve(sha512: sum, filename: "photo.png", uti: "public.png")
        let second = resolver.resolve(sha512: sum, filename: "photo.png", uti: "public.png")
        #expect(first != nil)
        #expect(second == first)
        #expect(hashed == 1)
    }

    @Test func unusableSumOrMissingContainerResolvesToNil() throws {
        let c = try AttachmentContainer.make { _ in }
        defer { c.cleanUp() }
        let resolver = AttachmentFileResolver(storeDir: c.storeDir)
        #expect(resolver.resolve(sha512: nil, filename: "photo.png", uti: nil) == nil)
        #expect(resolver.resolve(sha512: "not-a-sha", filename: "photo.png", uti: nil) == nil)
        #expect(resolver.resolve(sha512: sha512Hex(blob), filename: "photo.png", uti: nil) == nil)
    }
}

@Suite struct AttachmentQueryTests {
    private func store(_ sql: String) throws -> (RemindersStore, AttachmentContainer) {
        let c = try AttachmentContainer.make { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: sql)
        }
        return (try RemindersStore.open(storeDir: c.storeDir), c)
    }

    @Test func jsonKeyOrderForSavedAndObjectRows() throws {
        let (s, c) = try store("""
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZUTI,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (1,42,'a.pdf','com.adobe.pdf','file',0);
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZUTI,ZWIDTH,ZHEIGHT,ZMARKEDFORDELETION)
          VALUES (2,42,'b.png','public.png',640,480,0);
        """)
        defer { c.cleanUp() }
        let json = JSONValue.array(attachmentRowsToJSON(s.attachments(pk: 42), resolve: { _ in nil }))
            .serialized(indent: nil, ensureAscii: true)
        #expect(json == #"[{"filename": "a.pdf", "type": "file", "path": null, "resolved": false, "uti": "com.adobe.pdf", "width": null, "height": null}, {"filename": "b.png", "type": "image", "path": null, "resolved": false, "uti": "public.png", "width": 640, "height": 480}]"#)
    }

    @Test func softDeletedAndLinkOnlyRowsAreExcluded() throws {
        let (s, c) = try store("""
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (1,42,'gone.png','image',1);
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZWIDTH,ZMARKEDFORDELETION) VALUES (2,42,'gone2.png',10,1);
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZURL,ZMARKEDFORDELETION) VALUES (3,42,'https://example.com',0);
        """)
        defer { c.cleanUp() }
        #expect(s.attachments(pk: 42).isEmpty)
    }

    @Test func batchPreloadGroupsAndSortsByFilename() throws {
        let (s, c) = try store("""
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (1,42,'z.pdf','file',0),(2,43,'m.png','image',0);
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZWIDTH,ZHEIGHT,ZMARKEDFORDELETION)
          VALUES (3,42,'a.png',10,20,0);
        """)
        defer { c.cleanUp() }
        let grouped = s.preloadAttachments([42, 43, 44])
        #expect(grouped[42]?.map(\.filename) == ["a.png", "z.pdf"])
        #expect(grouped[43]?.map(\.type) == ["image"])
        #expect(grouped[44] == nil)
    }

    /// One listing must not grow a query per reminder (upstream M2 regression).
    @Test func listSerializationQueriesEachAttachmentTableOnce() throws {
        let (s, c) = try store("""
        INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
        INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
          VALUES (10,'a',1,1,0,0),(11,'b',1,1,0,0),(12,'c',1,1,0,0);
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (1,10,'one.png','image',0),(2,11,'two.png','image',0);
        """)
        defer { c.cleanUp() }
        final class Trace: @unchecked Sendable { var statements: [String] = [] }
        let trace = Trace()
        try s.queue.read { db in db.trace { trace.statements.append("\($0)") } }

        let rows = s.reminders(listPk: 1, completed: false, topLevel: true)
        _ = serializeReminders(rows, store: s)

        #expect(rows.count == 3)
        #expect(trace.statements.filter { $0.hasPrefix("SELECT") && $0.contains("ZREMCDSAVEDATTACHMENT") }.count == 1)
        #expect(trace.statements.filter { $0.hasPrefix("SELECT") && $0.contains("FROM ZREMCDOBJECT WHERE ZREMINDER2 IN") }.count == 1)
    }
}

@Suite struct AttachmentSchemaDriftTests {
    /// A store whose attachment tables predate ZSHA512SUM/ZWIDTH still serializes, with nulls.
    @Test func olderSchemaSerializesWithNulls() throws {
        let c = try AttachmentContainer.make { db in
            try db.execute(sql: """
            CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, ZPARENTREMINDER INTEGER,
              ZCOMPLETED INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0);
            CREATE TABLE ZREMCDSAVEDATTACHMENT (Z_PK INTEGER PRIMARY KEY, ZREMINDER INTEGER,
              ZFILENAME TEXT, ZUTI TEXT, ZATTACHMENTTYPERAWVALUE TEXT, ZMARKEDFORDELETION INTEGER DEFAULT 0);
            CREATE TABLE ZREMCDOBJECT (Z_PK INTEGER PRIMARY KEY, ZREMINDER2 INTEGER, ZFILENAME TEXT,
              ZURL TEXT, ZMARKEDFORDELETION INTEGER DEFAULT 0);
            INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZUTI,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
              VALUES (1,42,'legacy.png','public.png','image',0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZMARKEDFORDELETION) VALUES (2,42,'object.png',0);
            """)
        }
        defer { c.cleanUp() }
        let s = try RemindersStore.open(storeDir: c.storeDir)
        let rows = s.attachments(pk: 42)
        #expect(rows.map(\.filename) == ["legacy.png", "object.png"])
        #expect(rows.allSatisfy { $0.sha512 == nil && $0.width == nil && $0.height == nil })
        // Without dimension columns an object file row can only be typed as a plain file.
        #expect(rows.map(\.type) == ["image", "file"])
        let payload = attachmentRowsToJSON(rows, resolve: s.resolveAttachmentPath)
        let json = JSONValue.array(payload).serialized(indent: nil, ensureAscii: true)
        #expect(json.contains(#""path": null, "resolved": false"#))
        #expect(s.preloadIndicators([42]) == [42: ReminderBadges(link: false, image: true)])
    }

    @Test func missingAttachmentTablesYieldNoAttachments() throws {
        let c = try AttachmentContainer.make { db in
            try db.execute(sql: """
            CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, ZPARENTREMINDER INTEGER,
              ZCOMPLETED INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZCOMPLETED) VALUES (42,0);
            """)
        }
        defer { c.cleanUp() }
        let s = try RemindersStore.open(storeDir: c.storeDir)
        #expect(s.attachments(pk: 42).isEmpty)
        #expect(s.preloadAttachments([42]).isEmpty)
        #expect(s.preloadIndicators([42]).isEmpty)
    }
}

@Suite struct AttachmentCommandTests {
    private let png = Data("a tiny pretend png".utf8)

    private func container() throws -> (AttachmentContainer, String) {
        let c = try AttachmentContainer.make { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
              VALUES (10,'With attachment',1,1,0,0,NULL),(11,'Plain',1,1,0,0,NULL);
            """)
        }
        let sum = try c.writeBlob(png, ext: ".png")
        try insertAttachment(c, sha: sum)
        return (c, sum)
    }

    private func insertAttachment(_ c: AttachmentContainer, sha: String) throws {
        let queue = try DatabaseQueue(path: c.storeDir.appendingPathComponent("Data-test.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZUTI,ZWIDTH,ZHEIGHT,ZSHA512SUM,ZMARKEDFORDELETION)
              VALUES (20,10,'photo.png','public.png',640,480,?,0);
            """, arguments: [sha])
        }
    }

    @Test func showJSONCarriesResolvedAttachmentsAndOmitsTheKeyOtherwise() throws {
        let (c, sum) = try container()
        defer { c.cleanUp() }
        let r = try CLIRunner.run(["show", "Work", "--json"], storeDir: c.storeDir)
        #expect(r.exit == 0)
        let items = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let withAttachment = items?.first { $0["id"] as? Int == 10 }
        let plain = items?.first { $0["id"] as? Int == 11 }
        let entry = (withAttachment?["attachments"] as? [[String: Any]])?.first
        #expect(entry?["filename"] as? String == "photo.png")
        #expect(entry?["type"] as? String == "image")
        #expect(entry?["resolved"] as? Bool == true)
        #expect((entry?["path"] as? String)?.hasSuffix("Files/Account-test/Attachments/\(sum).png") == true)
        #expect(entry?["uti"] as? String == "public.png")
        #expect(entry?["width"] as? Int == 640)
        #expect(entry?["height"] as? Int == 480)
        #expect(plain?["attachments"] == nil)
    }

    @Test func infoJSONCarriesAttachmentsForParentAndSubtask() throws {
        let c = try AttachmentContainer.make { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (10,'Parent',1,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER)
              VALUES (11,'Child',1,1,0,0,10);
            INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
              VALUES (1,10,'parent.png','image',0),(2,11,'child.png','image',0);
            """)
        }
        defer { c.cleanUp() }
        let r = try CLIRunner.run(["info", "10", "--json"], storeDir: c.storeDir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let parent = (d?["attachments"] as? [[String: Any]])?.first
        #expect(parent?["filename"] as? String == "parent.png")
        #expect(parent?["resolved"] as? Bool == false)
        #expect(parent?["path"] is NSNull)
        let child = ((d?["subtasks"] as? [[String: Any]])?.first?["attachments"] as? [[String: Any]])?.first
        #expect(child?["filename"] as? String == "child.png")
        // One attachments key per reminder: the subtask payload is not hydrated twice.
        #expect(r.stdout.components(separatedBy: "\"attachments\"").count == 3)
    }

    @Test func todayJSONCarriesAttachments() throws {
        let c = try AttachmentContainer.make { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
              VALUES (10,'Due now',1,1,0,0,?);
            INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
              VALUES (1,10,'today.png','image',0);
            """, arguments: [AppleEpoch.toTs(Date())])
        }
        defer { c.cleanUp() }
        let r = try CLIRunner.run(["today", "--json"], storeDir: c.storeDir)
        #expect(r.exit == 0)
        let items = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect((items?.first?["attachments"] as? [[String: Any]])?.first?["filename"] as? String == "today.png")
    }

    @Test func exportJSONCarriesAttachments() throws {
        let (c, _) = try container()
        defer { c.cleanUp() }
        let r = try CLIRunner.run(["export", "--format", "json"], storeDir: c.storeDir)
        #expect(r.exit == 0)
        let items = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let entry = (items?.first { $0["id"] as? Int == 10 }?["attachments"] as? [[String: Any]])?.first
        #expect(entry?["filename"] as? String == "photo.png")
    }
}
