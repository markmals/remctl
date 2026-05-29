import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct TemplateCommandTests {
    private func uuidData(_ s: String) -> Data {
        withUnsafeBytes(of: UUID(uuidString: s)!.uuid) { Data($0) }
    }

    /// Mirrors the Python _template_db fixture.
    private func fixture() throws -> URL {
        let publicUUID = uuidData("3A6B9DE5-80A4-4180-8AFC-1D261121E344")
        let metadata = Data([0x01]) + Data(#"{"title":"Colosseum","flagged":1,"priority":1,"hashtags":[{"name":"rome"}],"recurrenceRules":[{"frequency":1,"interval":1}]}"#.utf8)
        return try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try FixtureDB.createTemplateSchema(db)
            try db.execute(sql:
                "INSERT INTO ZREMCDTEMPLATE (Z_PK,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION,ZCREATIONDATE,ZLASTMODIFIEDDATE,ZPUBLICLINKCREATIONDATE,ZPUBLICLINKLASTMODIFIEDDATE,ZBADGEEMBLEM,ZPUBLICLINKURLUUID,ZPUBLICLINKCONFIGURATIONDATA) VALUES (1,'Rome: Things To See','TEMPLATE-1',0,100,200,300,400,'star',?,?)",
                arguments: [publicUUID, Data([0x01, 0x02])])
            try db.execute(sql:
                "INSERT INTO ZREMCDSAVEDREMINDER (Z_PK,ZTITLE,ZCKIDENTIFIER,ZTEMPLATE,ZPRIORITY,ZCREATIONDATE,ZMETADATA,ZMARKEDFORDELETION) VALUES (10,'Colosseum','ITEM-1',1,1,150,?,0)",
                arguments: [metadata])
            try db.execute(sql:
                "INSERT INTO ZREMCDBASESECTION (Z_PK,Z_ENT,ZDISPLAYNAME,ZCANONICALNAME,ZTEMPLATE,ZCKIDENTIFIER,ZCREATIONDATE,ZMARKEDFORDELETION) VALUES (20,8,'Ancient Rome','Ancient Rome',1,'SECTION-1',125,0)")
        }
    }

    @Test func emptyTemplatesJSON() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db); try FixtureDB.createTemplateSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["templates", "--json"], storeDir: dir)
        #expect(r.exit == 0); #expect(r.stdout == "[]\n")
    }

    @Test func emptyTemplatesHuman() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db); try FixtureDB.createTemplateSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["templates"], storeDir: dir)
        #expect(r.stdout == "No templates\n")
    }

    @Test func templatesJSONReportsCountsAndPublicLink() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["templates", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let t = arr?.first
        #expect(t?["name"] as? String == "Rome: Things To See")
        #expect(t?["itemCount"] as? Int == 1)
        #expect(t?["sectionCount"] as? Int == 1)
        let pub = t?["publicLink"] as? [String: Any]
        #expect(pub?["uuid"] as? String == "3A6B9DE5-80A4-4180-8AFC-1D261121E344")
        #expect(pub?["url"] as? String == "https://www.icloud.com/reminders/template/3A6B9DE5-80A4-4180-8AFC-1D261121E344#Rome:_Things_To_See")
        #expect(pub?["configurationLength"] as? Int == 2)
    }

    @Test func templateInfoJSONSectionsAndItems() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["template-info", "Rome: Things To See", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let sections = d?["sections"] as? [[String: Any]]
        #expect(sections?.first?["name"] as? String == "Ancient Rome")
        let items = d?["items"] as? [[String: Any]]
        let item = items?.first
        #expect(item?["title"] as? String == "Colosseum")
        #expect(item?["priority"] as? String == "high")
        #expect(item?["flagged"] as? Bool == true)
        #expect((item?["tags"] as? [String]) == ["rome"])
    }

    @Test func templateInfoNotFound() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["template-info", "Nope"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("Error: template not found: Nope"))
    }

    @Test func templateInfoNeitherArg() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["template-info"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("pass a template name or --template-id"))
    }
}
