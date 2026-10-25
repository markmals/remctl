import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct ReminderBadgeTests {
    let off = Ansi(enabled: false)
    let link = "🔗"
    let image = "🌄"

    private func row(completed: Int = 0) -> DictRow {
        DictRow(["Z_PK": 42, "ZTITLE": "Badge target", "list_name": "Projects",
                 "ZCOMPLETED": completed, "ZFLAGGED": 0, "ZPRIORITY": 0])
    }

    @Test func noBadgesByDefault() {
        let line = fmt(row(), tags: [], subtaskCount: 0, ansi: off)
        #expect(line == "[ ] #42 Badge target")
    }

    @Test func linkOnly() {
        let line = fmt(row(), tags: [], subtaskCount: 0, ansi: off, badges: ReminderBadges(link: true))
        #expect(line == "[ ] #42 Badge target \(link)")
    }

    @Test func imageOnly() {
        let line = fmt(row(), tags: [], subtaskCount: 0, ansi: off, badges: ReminderBadges(image: true))
        #expect(line == "[ ] #42 Badge target \(image)")
    }

    @Test func bothInLinkThenImageOrderAfterTagsAndSubtasks() {
        let line = fmt(row(), tags: ["work"], subtaskCount: 2, ansi: off,
                       badges: ReminderBadges(link: true, image: true))
        #expect(line == "[ ] #42 Badge target #work [2 subtasks] \(link) \(image)")
    }

    @Test func completedReminderKeepsItsBadges() {
        let line = fmt(row(completed: 1), tags: [], subtaskCount: 0, ansi: Ansi(enabled: true),
                       badges: ReminderBadges(link: true, image: true))
        #expect(line.hasSuffix(" \(link) \(image)"))
    }

    @Test func badgesStayOutOfTheEventKitFallback() {
        let item = EventKitItemSnapshot(eventKitId: "EK-1", title: "Linked", list: "Work",
                                        url: "https://example.com")
        let out = renderEventKitRead(items: [item], heading: "Work (EventKit limited)",
                                     emptyMessage: "none", ansi: off)
        #expect(out.contains("Linked"))
        #expect(!out.contains(link))
        #expect(!out.contains(image))
    }
}

@Suite struct IndicatorPreloadTests {
    private func store(_ sql: String) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: sql)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    @Test func flagsPerReminderAndSkipsSoftDeletedRows() throws {
        let (s, dir) = try store("""
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZUTI,ZWIDTH,ZHEIGHT,ZMARKEDFORDELETION)
          VALUES (1,42,'a.png','public.png',10,10,0);
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZURL,ZMARKEDFORDELETION) VALUES (2,43,'https://x.example',0);
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (3,44,'b.png','image',1);
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (4,45,'url',0);
        INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
          VALUES (5,46,'doc.pdf','file',0);
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flags = s.preloadIndicators([42, 43, 44, 45, 46])
        #expect(flags[42] == ReminderBadges(image: true))
        #expect(flags[43] == ReminderBadges(link: true))
        #expect(flags[44] == nil)
        #expect(flags[45] == ReminderBadges(link: true))
        #expect(flags[46] == nil)
    }

    @Test func linkAndImageOnTheSameReminder() throws {
        let (s, dir) = try store("""
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZWIDTH,ZHEIGHT,ZMARKEDFORDELETION)
          VALUES (1,42,'a.png',10,10,0);
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZURL,ZMARKEDFORDELETION) VALUES (2,42,'https://x.example',0);
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.preloadIndicators([42]) == [42: ReminderBadges(link: true, image: true)])
    }

    /// A file object row without dimensions is an attachment, not an image badge.
    @Test func plainFileObjectRowIsNotAnImage() throws {
        let (s, dir) = try store("""
        INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZMARKEDFORDELETION) VALUES (1,42,'notes.txt',0);
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.preloadIndicators([42]).isEmpty)
    }
}

@Suite struct BadgeOutputTests {
    private let link = "🔗"
    private let image = "🌄"

    private func fixture() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION)
              VALUES (10,'Has both',1,1,0,0),(11,'Has nothing',1,1,0,0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZFILENAME,ZUTI,ZWIDTH,ZHEIGHT,ZMARKEDFORDELETION)
              VALUES (20,10,'photo.png','public.png',640,480,0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZURL,ZMARKEDFORDELETION) VALUES (21,10,'https://example.com',0);
            """)
        }
    }

    @Test func humanShowEndsTheLineWithBothBadges() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["show", "Work"], storeDir: dir)
        #expect(r.exit == 0)
        let lines = r.stdout.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasSuffix("Has both \(link) \(image)") })
        #expect(lines.contains { $0.hasSuffix("Has nothing") })
    }

    @Test func badgesAreAbsentFromTableJSONAndCSV() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [["show", "Work", "--format", "table"], ["show", "Work", "--json"],
                     ["today", "--json"], ["export", "--format", "csv"]] {
            let r = try CLIRunner.run(args, storeDir: dir)
            #expect(r.exit == 0, "\(args)")
            #expect(!r.stdout.contains(link), "\(args)")
            #expect(!r.stdout.contains(image), "\(args)")
        }
    }

    @Test func subtaskAndInfoLinesCarryBadges() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (10,'Parent',1,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER)
              VALUES (11,'Child',1,1,0,0,10);
            INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION)
              VALUES (20,11,'child.png','image',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let subtasks = try CLIRunner.run(["subtasks", "10"], storeDir: dir)
        #expect(subtasks.stdout.contains("Child \(image)"))
        let info = try CLIRunner.run(["info", "10"], storeDir: dir)
        #expect(info.stdout.contains("Child \(image)"))
    }
}
