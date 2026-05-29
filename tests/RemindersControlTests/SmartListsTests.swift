import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct FilterDecodeTests {
    private func summaryField(_ result: FilterDecodeResult, _ key: String) -> JSONValue? {
        result.summary?.first(where: { $0.0 == key })?.1
    }
    private func decode(_ s: String) -> FilterDecodeResult { decodeSmartListFilterBlob(Data(s.utf8)) }

    @Test func nullBlob() {
        let r = decodeSmartListFilterBlob(nil)
        #expect(r.encoding == nil); #expect(r.payload == nil); #expect(r.summary == nil); #expect(r.error == nil)
    }
    @Test func emptyObjectIsAll() {
        let r = decode("{}")
        #expect(r.encoding == "json")
        #expect(summaryField(r, "kind")?.asStringT == "all")
        #expect(summaryField(r, "description")?.asStringT == "All reminders")
    }
    @Test func flaggedFilter() {
        let r = decode(#"{"flagged":true}"#)
        #expect(summaryField(r, "kind")?.asStringT == "flagged")
        #expect(summaryField(r, "supported")?.asBoolT == true)
    }
    @Test func singlePriority() {
        let r = decode(#"{"priorities":["high"]}"#)
        #expect(summaryField(r, "kind")?.asStringT == "priority")
        #expect(summaryField(r, "description")?.asStringT == "Priority: high")
        #expect(summaryField(r, "supported")?.asBoolT == true)
    }
    @Test func legacySelectedTagsUnsupportedNonMaterializing() {
        let r = decode(#"{"hashtags":{"hashtags":["remctl"]}}"#)
        // single hashtags family that is unsupported -> top-level unsupported
        #expect(summaryField(r, "kind")?.asStringT == "unsupported")
        #expect(summaryField(r, "supported")?.asBoolT == false)
        #expect(summaryField(r, "materializes")?.asBoolT == false)
    }
    @Test func dateAfterFilter() {
        let r = decode(#"{"date":{"afterDate":"15-05-2026"}}"#)
        #expect(summaryField(r, "kind")?.asStringT == "date")
        #expect(summaryField(r, "description")?.asStringT == "After date: 15-05-2026")
    }
    @Test func timeAfternoon() {
        let r = decode(#"{"time":{"afternoon":""}}"#)
        #expect(summaryField(r, "kind")?.asStringT == "time")
        #expect(summaryField(r, "description")?.asStringT == "Afternoon")
    }
    @Test func tagsIncludeExcludeSupported() {
        let r = decode(#"{"hashtags":{"hashtags":{"operation":"or","include":["a"],"exclude":["b"]}}}"#)
        #expect(summaryField(r, "kind")?.asStringT == "tags")
        #expect(summaryField(r, "description")?.asStringT == "Tags any selected: include a, exclude b")
        #expect(summaryField(r, "supported")?.asBoolT == true)
    }
}

@Suite struct SmartListsCommandTests {
    @Test func emptyHuman() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["smart-lists"], storeDir: dir)
        #expect(r.exit == 0); #expect(r.stdout == "No smart lists\n")
    }
    @Test func emptyJSON() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["smart-lists", "--json"], storeDir: dir)
        #expect(r.stdout == "[]\n")
    }
    // Mirrors test_smart_lists_json_decodes_builtin_and_custom_rows.
    @Test func decodesBuiltinAndCustom() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,ZNAME,ZCKIDENTIFIER,Z_ENT,ZSMARTLISTTYPE,ZFILTERDATA,ZISPINNEDBYCURRENTUSER,ZPINNEDDATE,ZMINIMUMSUPPORTEDAPPVERSION,ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION,ZMARKEDFORDELETION)
            VALUES (1,NULL,'BUILTIN-1',4,'com.apple.reminders.smartlist.flagged',NULL,1,123.0,1,0,0);
            INSERT INTO ZREMCDBASELIST (Z_PK,ZNAME,ZCKIDENTIFIER,Z_ENT,ZSMARTLISTTYPE,ZFILTERDATA,ZPINNEDDATE,ZMINIMUMSUPPORTEDAPPVERSION,ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION,ZMARKEDFORDELETION)
            VALUES (2,'High Priority','CUSTOM-1',4,'com.apple.reminders.smartlist.custom',?,456.0,20220430,20220430,0);
            INSERT INTO ZREMCDBASELIST (Z_PK,ZNAME,Z_ENT,ZMARKEDFORDELETION) VALUES (10,'Reminders',3,0);
            """, arguments: [Data(#"{"priorities":["high"]}"#.utf8)])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["smart-lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(arr?.count == 2)   // Z_ENT=3 regular list excluded
        let flagged = arr?[0], custom = arr?[1]
        #expect(flagged?["kind"] as? String == "built-in")
        #expect(flagged?["name"] as? String == "Flagged")
        #expect(flagged?["filterLength"] as? Int == 0)
        #expect(flagged?["pinned"] as? Bool == true)
        #expect(flagged?["pinnedDate"] as? Double == 123.0)
        #expect(custom?["kind"] as? String == "custom")
        #expect(custom?["pinned"] as? Bool == true)   // from pinnedDate > 0
        #expect(custom?["pinnedDate"] as? Double == 456.0)
        #expect(custom?["minimumSupportedVersion"] as? Int == 20220430)
        let filter = custom?["filter"] as? [String: Any]
        #expect(filter?["kind"] as? String == "priority")
        let filterJSON = custom?["filterJSON"] as? [String: Any]
        #expect((filterJSON?["priorities"] as? [String]) == ["high"])
    }
}

private extension JSONValue {
    var asStringT: String? { if case let .string(s) = self { return s }; return nil }
    var asBoolT: Bool? { if case let .bool(b) = self { return b }; return nil }
}
