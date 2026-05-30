import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct NormalizeListLookupNameTests {
    // Fixtures verified byte-for-byte against the Python source
    // (unicodedata.normalize("NFKC", s).casefold() + category M/P/S/Z + whitespace collapse).
    @Test func plainAndCaseAndPunctuation() {
        #expect(normalizeListLookupName("Café") == "café")
        #expect(normalizeListLookupName(" Hello,  World! ") == "hello world")
        #expect(normalizeListLookupName("A_B-C") == "a b c")
        #expect(normalizeListLookupName(" wx\t?z ") == "wx z")
        #expect(normalizeListLookupName("  ") == "")
        #expect(normalizeListLookupName("") == "")
    }
    @Test func nfkcCompatibilityMapping() {
        // ligature ﬀ -> ff; fullwidth ＡＢＣ１２３ -> abc123; fullwidth digit; Roman numeral Ⅻ -> xii
        #expect(normalizeListLookupName("ﬀ") == "ff")
        #expect(normalizeListLookupName("ＡＢＣ１２３") == "abc123")
        #expect(normalizeListLookupName("full３width") == "full3width")
        #expect(normalizeListLookupName("Ⅻ") == "xii")
    }
    @Test func casefoldDivergesFromLowercased() {
        // THE PARITY HAZARD: Python str.casefold() != str.lower().
        // ß -> ss, final sigma ς -> σ, full-word ΣΟΦΟΣ -> σοφοσ.
        #expect(normalizeListLookupName("straße") == "strasse")
        #expect(normalizeListLookupName("ΣΟΦΟΣ") == "σοφοσ")
        #expect(normalizeListLookupName("final-ς") == "final σ")
        #expect(normalizeListLookupName("αΒΓ") == "αβγ")
    }
    @Test func combiningMarkAfterCasefoldIsCollapsed() {
        // İ (U+0130) casefolds to "i" + U+0307 (combining dot, category Mn);
        // iterating scalars (NOT grapheme clusters) keeps the dot separate -> collapses to a space.
        #expect(normalizeListLookupName("İstanbul") == "i stanbul")
    }
    @Test func symbolsAndEmojiCollapse() {
        // emoji (category So) collapses to a single space between letters; leading/trailing dropped.
        #expect(normalizeListLookupName("foo😀bar") == "foo bar")
        #expect(normalizeListLookupName("😀only😀") == "only")
    }
}

@Suite struct ListResolveFourTierTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    @Test func tier0ById() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (7,3,'Work','ck-7',0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case let .found(id, title, uuid) = s.resolveListRef(name: nil, listId: 7) else { Issue.record("expected found"); return }
        #expect(id == 7); #expect(title == "Work"); #expect(uuid == "ck-7")
        // unknown id -> notFound
        if case .notFound = s.resolveListRef(name: nil, listId: 999) {} else { Issue.record("expected notFound") }
    }

    @Test func tier1ExactWins() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (2,3,'work',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case let .found(id, _, _) = s.resolveListRef(name: "Work", listId: nil) else { Issue.record("expected found"); return }
        #expect(id == 1)  // exact beats the casefold sibling
    }

    @Test func tier2CasefoldUnique() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (3,3,'Groceries',0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case let .found(id, title, _) = s.resolveListRef(name: "GROCERIES", listId: nil) else { Issue.record("expected found"); return }
        #expect(id == 3); #expect(title == "Groceries")
    }

    @Test func tier3NormalizedUnique() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (4,3,'My — List',0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // "my list" normalizes both candidate and query to the same form.
        guard case let .found(id, _, _) = s.resolveListRef(name: "my list", listId: nil) else { Issue.record("expected found"); return }
        #expect(id == 4)
    }

    @Test func exactAmbiguousReturnsCandidates() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (5,3,'Dup',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (6,3,'Dup',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case let .ambiguous(cands) = s.resolveListRef(name: "Dup", listId: nil) else { Issue.record("expected ambiguous"); return }
        #expect(cands.map { $0.id }.sorted() == [5, 6])
    }

    @Test func notFound() throws {
        let (s, dir) = try store { _ in }
        defer { try? FileManager.default.removeItem(at: dir) }
        if case .notFound = s.resolveListRef(name: "nope", listId: nil) {} else { Issue.record("expected notFound") }
    }
}

@Suite struct SmartListResolveTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    @Test func smartTier0ById() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (20,4,'Soon','ck-20','com.apple.reminders.smartlist.custom',0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case let .found(id, title, uuid) = s.resolveSmartListRef(name: nil, smartListId: 20) else { Issue.record("expected found"); return }
        #expect(id == 20); #expect(title == "Soon"); #expect(uuid == "ck-20")
    }

    @Test func smartCasefoldAndNormalizedAndAmbiguous() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (21,4,'Today','com.apple.reminders.smartlist.custom',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (22,4,'Flagged—Soon','com.apple.reminders.smartlist.custom',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (23,4,'Dup','com.apple.reminders.smartlist.custom',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (24,4,'Dup','com.apple.reminders.smartlist.custom',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case let .found(id2, _, _) = s.resolveSmartListRef(name: "TODAY", smartListId: nil) else { Issue.record("expected found"); return }
        #expect(id2 == 21)
        guard case let .found(id3, _, _) = s.resolveSmartListRef(name: "flagged soon", smartListId: nil) else { Issue.record("expected found"); return }
        #expect(id3 == 22)
        guard case let .ambiguous(cands) = s.resolveSmartListRef(name: "Dup", smartListId: nil) else { Issue.record("expected ambiguous"); return }
        #expect(cands.map { $0.id }.sorted() == [23, 24])
    }
}

@Suite struct ListCkidTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    @Test func listCkidEnt3OnlyAndNullToNil() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (1,3,'L','ck-1',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (2,3,'N',NULL,0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (3,3,'E','',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (4,3,'D','ck-4',1);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (5,4,'S','ck-5','com.apple.reminders.smartlist.custom',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.listCkid(pk: 1) == "ck-1")
        #expect(s.listCkid(pk: 2) == nil)   // NULL -> nil
        #expect(s.listCkid(pk: 3) == nil)   // empty -> nil
        #expect(s.listCkid(pk: 4) == nil)   // marked-for-deletion
        #expect(s.listCkid(pk: 5) == nil)   // Z_ENT=4 (smart list) excluded
    }

    @Test func smartListCkidEnt4OrSmartTypeAndNullToNil() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (10,4,'S','ck-10',NULL,0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (11,3,'T','ck-11','com.apple.reminders.smartlist.custom',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (12,3,'R','ck-12',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (13,4,'X',NULL,NULL,0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (14,4,'D','ck-14',NULL,1);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.smartListCkid(pk: 10) == "ck-10")  // Z_ENT=4
        #expect(s.smartListCkid(pk: 11) == "ck-11")  // Z_ENT=3 but ZSMARTLISTTYPE set
        #expect(s.smartListCkid(pk: 12) == nil)      // plain list -> excluded
        #expect(s.smartListCkid(pk: 13) == nil)      // NULL ckid -> nil
        #expect(s.smartListCkid(pk: 14) == nil)      // marked-for-deletion
    }
}

@Suite struct CustomSmartListQueryTests {
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    @Test func exactNameCountAndMatches() throws {
        let (s, dir) = try store { db in
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (30,4,'Soon','ck-30','com.apple.reminders.smartlist.custom',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (31,4,'Soon','ck-31','com.apple.reminders.smartlist.custom',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (32,4,'Soon','ck-32','com.apple.reminders.smartlist.builtin',0);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (33,4,'Soon','ck-33','com.apple.reminders.smartlist.custom',1);
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZSMARTLISTTYPE,ZMARKEDFORDELETION) VALUES (34,4,'soon','ck-34','com.apple.reminders.smartlist.custom',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.customSmartListExactNameCount(name: "Soon") == 2)  // 30,31 (32 wrong type, 33 deleted, 34 different case)
        let matches = s.customSmartListMatches(name: "Soon")
        #expect(matches.map { $0.pk } == [30, 31])  // ORDER BY Z_PK
        #expect(matches.map { $0.name } == ["Soon", "Soon"])
        #expect(matches.map { $0.ckid ?? "" } == ["ck-30", "ck-31"])
    }
}
