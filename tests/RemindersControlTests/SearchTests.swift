import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct SearchCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "milk"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No reminders matching 'milk'\n")
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "nothing", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedShowsSearchHeader() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Buy milk',10,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (2,'Buy eggs',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "milk"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Search: milk"))
        #expect(r.stdout.contains("Buy milk"))
        #expect(!r.stdout.contains("Buy eggs"))
        #expect(r.stdout.contains("1 result"))
    }

    @Test func pluralResultsWording() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Buy item a',10,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (2,'Buy item b',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "Buy"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("2 results"))
    }

    @Test func completedFlagIncludesCompletedItems() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (1,'Done task',10,1,1,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // Without --completed: not found
        let r1 = try CLIRunner.run(["search", "Done"], storeDir: dir)
        #expect(r1.stdout.contains("No reminders matching"))
        // With --completed: found
        let r2 = try CLIRunner.run(["search", "Done", "--completed"], storeDir: dir)
        #expect(r2.stdout.contains("Done task"))
    }

    @Test func jsonPopulatedHasTitle() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'List',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
            VALUES (42,'Find me',10,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "Find", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 1)
        #expect(parsed?.first?["title"] as? String == "Find me")
        #expect(parsed?.first?["id"] as? Int == 42)
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Matching, list scope and paging (upstream b8b601c). The fixture mirrors
// upstream's tests/test_search_batch_location.py store: two lists named "Work",
// one rich link, one deleted rich link, and 150 bulk rows for the page math.
// ──────────────────────────────────────────────────────────────────────────────

enum SearchFixture {
    static func build(_ db: Database) throws {
        try FixtureDB.createRemindersSchema(db)
        try db.execute(sql: """
        INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES
          (1,3,'Work','L1',0), (2,3,'Errands','L2',0), (3,3,'Work','L3',0);
        INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZNOTES,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES
          (1,'Read the review',NULL,1,1,0,0),
          (2,'Café meeting',NULL,2,1,0,0),
          (3,'100% done_ok\\path',NULL,2,1,0,0),
          (4,'Other story',NULL,3,1,0,0),
          (5,'Straße sign',NULL,2,1,0,0),
          (6,'Plain','notes mention Macstories.net once',3,1,0,0);
        INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER2,ZURL,ZMARKEDFORDELETION) VALUES
          (1,20,1,'https://www.macstories.net/stories/remctl-review/',0),
          (2,20,4,'https://www.macstories.net/deleted-link/',1);
        """)
        for n in 0..<150 {
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (?,?,2,1,0,0)",
                           arguments: [100 + n, "Bulk item \(n)"])
        }
    }

    static func tempStore() throws -> URL { try FixtureDB.tempStore(build) }
}

@Suite struct SearchQueryTests {
    private func store() throws -> (RemindersStore, URL) {
        let dir = try SearchFixture.tempStore()
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    @Test func matchesASavedRichLinkButNotADeletedOne() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.search("remctl-review").map { $0.int("Z_PK")! } == [1])
        // The same text in the notes still matches; the deleted link on #4 does not.
        #expect(s.search("macstories.net").map { $0.int("Z_PK")! } == [6, 1])
    }

    @Test func ignoresCaseAndAccents() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.search("CAFE").map { $0.int("Z_PK")! } == [2])
        #expect(s.search("café").map { $0.int("Z_PK")! } == [2])
        #expect(s.search("strasse").map { $0.int("Z_PK")! } == [5])
    }

    @Test func treatsWildcardsAndBackslashesLiterally() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.search("%").map { $0.int("Z_PK")! } == [3])
        #expect(s.search("_").map { $0.int("Z_PK")! } == [3])
        #expect(s.search("\\").map { $0.int("Z_PK")! } == [3])
        #expect(s.search("done_ok").map { $0.int("Z_PK")! } == [3])
        #expect(s.search("done%ok").isEmpty)
    }

    @Test func scopesToOneListByPrimaryKey() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.search("story", listPk: 3).map { $0.int("Z_PK")! } == [4])
        #expect(s.search("story", listPk: 1).isEmpty)
        #expect(s.searchCount("story", listPk: 3) == 1)
    }

    @Test func pagesThroughEveryMatchWithAnHonestTotal() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.searchCount("bulk") == 150)
        let first = s.search("bulk", limit: 100, offset: 0).map { $0.int("Z_PK")! }
        let second = s.search("bulk", limit: 100, offset: 100).map { $0.int("Z_PK")! }
        #expect(first.count == 100)
        #expect(second.count == 50)
        #expect(first.first == 249)  // newest first
        #expect(Set(first + second) == Set(100...249))
    }
}

@Suite struct SearchPagingCLITests {
    @Test func pagedJSONReportsTotalAndNextOffset() throws {
        let dir = try SearchFixture.tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try CLIRunner.run(["search", "bulk", "--limit", "100", "--json"], storeDir: dir)
        #expect(first.exit == 0)
        let page = try JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any]
        #expect(page?["count"] as? Int == 100)
        #expect(page?["total"] as? Int == 150)
        #expect(page?["offset"] as? Int == 0)
        #expect(page?["limit"] as? Int == 100)
        #expect(page?["hasMore"] as? Bool == true)
        #expect(page?["nextOffset"] as? Int == 100)
        #expect((page?["items"] as? [[String: Any]])?.count == 100)

        let last = try CLIRunner.run(["search", "bulk", "--limit", "100", "--offset", "100", "--json"], storeDir: dir)
        let lastPage = try JSONSerialization.jsonObject(with: Data(last.stdout.utf8)) as? [String: Any]
        #expect(lastPage?["count"] as? Int == 50)
        #expect(lastPage?["hasMore"] as? Bool == false)
        #expect(lastPage?["nextOffset"] is NSNull)
    }

    @Test func unpagedJSONStaysAnArrayAndWarnsWhenCutShort() throws {
        let dir = try SearchFixture.tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "bulk", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let items = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(items?.count == 100)
        #expect(r.stderr.contains("showing 100 of 150 matches"))
        #expect(r.stderr.contains("--offset 100"))
    }

    @Test func humanOutputCountsThePageAgainstTheTotal() throws {
        let dir = try SearchFixture.tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "bulk", "--limit", "2"], storeDir: dir)
        #expect(r.stdout.contains("Showing 1-2 of 150 results"))
        #expect(r.stdout.contains("Next page: --offset 2"))
        let past = try CLIRunner.run(["search", "bulk", "--offset", "150"], storeDir: dir)
        #expect(past.stdout == "No reminders matching 'bulk' past offset 150 (150 total)\n")
    }

    @Test func duplicateListNamesAskForTheNumericId() throws {
        let dir = try SearchFixture.tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "story", "--list", "Work", "--json"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("multiple lists match 'Work'"))
        #expect(r.stderr.contains("--list-id with one of: 1 (Work), 3 (Work)"))
    }

    @Test func listIdScopesTheSearchAndNamesTheListInAPage() throws {
        let dir = try SearchFixture.tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try CLIRunner.run(["search", "story", "--list-id", "3", "--json"], storeDir: dir)
        let items = try JSONSerialization.jsonObject(with: Data(plain.stdout.utf8)) as? [[String: Any]]
        #expect(items?.compactMap { $0["id"] as? Int } == [4])

        let paged = try CLIRunner.run(["search", "story", "--list-id", "3", "--offset", "0", "--json"], storeDir: dir)
        let page = try JSONSerialization.jsonObject(with: Data(paged.stdout.utf8)) as? [String: Any]
        #expect((page?["items"] as? [[String: Any]])?.compactMap { $0["id"] as? Int } == [4])
        let listRef = page?["list"] as? [String: Any]
        #expect(listRef?["id"] as? Int == 3)
        #expect(listRef?["title"] as? String == "Work")

        let scoped = try CLIRunner.run(["search", "story", "--list-id", "3"], storeDir: dir)
        #expect(scoped.stdout.contains("Search: story in Work"))
    }

    @Test func pagingBoundsAreCheckedBeforeAnyRead() throws {
        let dir = try SearchFixture.tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let low = try CLIRunner.run(["search", "bulk", "--limit", "0"], storeDir: dir)
        #expect(low.exit == 1)
        #expect(low.stderr == "Error: --limit must be between 1 and 500.\n")
        let high = try CLIRunner.run(["search", "bulk", "--limit", "501", "--json"], storeDir: dir)
        #expect(high.exit == 1)
        let payload = try JSONSerialization.jsonObject(with: Data(high.stderr.utf8)) as? [String: Any]
        #expect(payload?["code"] as? String == "invalid_limit")
        #expect(payload?["status"] as? String == "error")
        let negative = try CLIRunner.run(["search", "bulk", "--offset=-1", "--json"], storeDir: dir)
        #expect(negative.exit == 1)
        let offsetPayload = try JSONSerialization.jsonObject(with: Data(negative.stderr.utf8)) as? [String: Any]
        #expect(offsetPayload?["code"] as? String == "invalid_offset")
    }

    @Test func viaEventKitRefusesNumericListIdsAndPaging() throws {
        let paged = try CLIRunner.run(["search", "milk", "--via-eventkit", "--limit", "10"])
        #expect(paged.exit == 2)
        #expect(paged.stderr.contains("--via-eventkit search does not support --limit or --offset."))
        let offset = try CLIRunner.run(["search", "milk", "--via-eventkit", "--offset", "10"])
        #expect(offset.exit == 2)
        #expect(offset.stderr.contains("does not support --limit or --offset"))
        let byId = try CLIRunner.run(["search", "milk", "--via-eventkit", "--list-id", "3"])
        #expect(byId.exit == 2)
        #expect(byId.stderr.contains("cannot use RemCTL numeric list ids"))
    }
}
