import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct ListsCommandTests {
    @Test func emptyJSONIsBracket() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "[]\n")
    }

    @Test func emptyHumanFooter() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists"], storeDir: dir)
        #expect(r.stdout == "Reminder Lists:\n\n0 lists\n")
    }

    @Test func jsonReportsGroceryMetadata() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS,ZSHOULDAUTOCATEGORIZEITEMS,ZGROCERYLOCALEID)
            VALUES (1,3,'Groceries',0,1,0,'en_US');
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS)
            VALUES (2,3,'Work',0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        // ORDER BY ZNAME: Groceries before Work
        let groceries = arr?[0]; let work = arr?[1]
        #expect(groceries?["title"] as? String == "Groceries")
        #expect(groceries?["listType"] as? String == "groceries")
        #expect(groceries?["isGroceries"] as? Bool == true)
        let g = groceries?["grocery"] as? [String: Any]
        #expect(g?["locale"] as? String == "en_US")
        #expect(g?["shouldCategorizeItems"] as? Bool == true)
        #expect(g?["shouldAutoCategorizeItems"] as? Bool == false)
        #expect(work?["listType"] as? String == "standard")
        #expect(work?["isGroceries"] as? Bool == false)
        #expect(work?["grocery"] == nil)   // omitted when not groceries and all-false
    }

    @Test func humanMarksGroceriesWithCarrot() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZSHOULDCATEGORIZEGROCERYITEMS) VALUES (1,3,'Groceries',0,1)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists"], storeDir: dir)
        #expect(r.stdout.contains("Groceries"))
        #expect(r.stdout.contains("🥕"))
        #expect(r.stdout.contains("(id: 1)"))
        #expect(r.stdout.contains("\n1 list\n"))
    }

    @Test func appearanceBadgeAndColorFallback() throws {
        // ZBADGEEMBLEM JSON with Emoji; ZCOLOR a non-plist blob -> default color.
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZBADGEEMBLEM,ZCOLOR) VALUES (1,3,'Projects',0,?,?)",
                           arguments: [#"{"Emoji" : "📌"}"#, Data("not-a-color".utf8)])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["lists", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let arr = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        let item = arr?.first
        let badge = item?["badge"] as? [String: Any]
        #expect(badge?["emoji"] as? String == "📌")
        let color = item?["color"] as? [String: Any]
        #expect(color?["hex"] as? String == "#007AFF")   // parse failure -> default blue
        #expect(color?["name"] as? String == "blue")
    }

    /// Reminders archives a list's color name/hex either as plain strings or, on some stores,
    /// as archived NSString objects (`{NS.string: …}`). Both must decode (upstream 7f88189).
    @Test func archivedColorStringsDecode() throws {
        for (label, mutable) in [("plain NSString", false), ("archived NS.string", true)] {
            let blob = ArchivedColor.blob(name: "red", hex: "#FF3B30", mutable: mutable)
            let dir = try FixtureDB.tempStore { db in
                try FixtureDB.createRemindersSchema(db)
                try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCOLOR) VALUES (1,3,'Projects',0,?)",
                               arguments: [blob])
                try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,ZNAME,ZCKIDENTIFIER,Z_ENT,ZSMARTLISTTYPE,ZCOLOR,ZMARKEDFORDELETION) VALUES (2,'Mine','CUSTOM-1',4,'com.apple.reminders.smartlist.custom',?,0)",
                               arguments: [blob])
            }
            defer { try? FileManager.default.removeItem(at: dir) }
            let lists = try CLIRunner.run(["lists", "--json"], storeDir: dir)
            let listColor = (try JSONSerialization.jsonObject(with: Data(lists.stdout.utf8)) as? [[String: Any]])?
                .first?["color"] as? [String: Any]
            #expect(listColor?["name"] as? String == "red", "\(label) list color")
            #expect(listColor?["hex"] as? String == "#FF3B30", "\(label) list hex")
            let smart = try CLIRunner.run(["smart-lists", "--json"], storeDir: dir)
            let smartColor = (try JSONSerialization.jsonObject(with: Data(smart.stdout.utf8)) as? [[String: Any]])?
                .first?["color"] as? [String: Any]
            #expect(smartColor?["name"] as? String == "red", "\(label) smart-list color")
        }
    }
}

/// Builds a ZCOLOR-shaped NSKeyedArchiver blob. `mutable` stores the strings as archived
/// NSString objects (`{"$class": …, "NS.string": …}`) instead of plain strings.
@objc(RemCTLTestArchivedColor) private final class ArchivedColor: NSObject, NSCoding {
    let name: NSString
    let hex: NSString
    init(name: NSString, hex: NSString) { self.name = name; self.hex = hex }
    init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "ckSymbolicColorName")
        coder.encode(hex, forKey: "daHexString")
    }
    static func blob(name: String, hex: String, mutable: Bool) -> Data {
        let wrap: (String) -> NSString = { mutable ? NSMutableString(string: $0) : NSString(string: $0) }
        return try! NSKeyedArchiver.archivedData(
            withRootObject: ArchivedColor(name: wrap(name), hex: wrap(hex)),
            requiringSecureCoding: false)
    }
}
