import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct InfoCommandTests {
    @Test func notFound() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "999"], storeDir: dir)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("Error: #999 not found"))
    }

    @Test func basicJSON() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (42,'Final README',1,1,0,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["id"] as? Int == 42)
        #expect(d?["title"] as? String == "Final README")
        #expect(d?["list"] as? String == "Work")
    }

    // Mirrors test_cmd_info_json_includes_private_rich_link_url + section via memberships.
    @Test func richLinkURLFallbackAndSection() throws {
        let blob = #"{"memberships":[{"memberID":"ABC","groupID":"SEC-1"}]}"#
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql:
                "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA) VALUES (1,3,'Projects',0,?)",
                arguments: [blob])
            try db.execute(sql: """
            INSERT INTO ZREMCDBASESECTION (Z_PK,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (5,'Playground',1,'SEC-1',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'Task',1,1,0,0,'ABC');
            INSERT INTO ZREMCDOBJECT (Z_PK,ZREMINDER2,ZURL,ZMARKEDFORDELETION) VALUES (90,42,'https://example.com/shortcuts-playground-plugin',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["url"] as? String == "https://example.com/shortcuts-playground-plugin")
        #expect(d?["section"] as? String == "Playground")
    }

    // Mirrors test_info_json_keeps_due_date_separate_from_display_alarm_date (TZ-pinned).
    @Test func dueDisplayAllDay() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE,ZDISPLAYDATEDATE,ZALLDAY)
            VALUES (42,'x',1,1,0,0,801216000,801215100,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir, extraEnv: ["TZ": "Europe/Rome"])
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["dueDate"] as? String == "2026-05-23T10:00:00")
        #expect(d?["displayDate"] as? String == "2026-05-23T09:45:00")
        #expect(d?["allDay"] as? Bool == false)
    }

    // Mirrors test_cmd_info_json_hydrates_subtask_attachments_and_alarms.
    @Test func subtaskHydrationAttachmentsAndAlarms() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (42,'Parent',1,1,0,0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZPARENTREMINDER) VALUES (43,'Child',1,1,0,0,42);
            INSERT INTO ZREMCDSAVEDATTACHMENT (Z_PK,ZREMINDER,ZFILENAME,ZATTACHMENTTYPERAWVALUE,ZMARKEDFORDELETION) VALUES (70,43,'child.png','image',0);
            -- relative alarm on the child: trigger ZTIMEINTERVAL=-600
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,15,43,81,0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZTIMEINTERVAL,ZMARKEDFORDELETION) VALUES (81,-600,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let subs = d?["subtasks"] as? [[String: Any]]
        let child = subs?.first
        let atts = child?["attachments"] as? [[String: Any]]
        #expect(atts?.first?["filename"] as? String == "child.png")
        let alarms = child?["alarms"] as? [[String: Any]]
        #expect(alarms?.first?["relativeOffset"] as? Int == -600)
        #expect(alarms?.first?["type"] as? String == "relative")
    }

    @Test func relativeAlarmLabelFormat() throws {
        // unit test of the label helper (oracle: -900 -> "15 minutes before due date")
        #expect(relativeAlarmLabel(-900) == "15 minutes before due date")
        #expect(relativeAlarmLabel(-3600) == "1 hour before due date")
        #expect(relativeAlarmLabel(86400) == "1 day after due date")
    }

    @Test func humanDetailBlock() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZFLAGGED,ZMARKEDFORDELETION) VALUES (42,'Ship',1,1,0,1,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Reminder #42"))
        #expect(r.stdout.contains("  Title:     Ship"))
        #expect(r.stdout.contains("  List:      Work"))
        #expect(r.stdout.contains("  Flagged:   Yes"))
        #expect(r.stdout.contains("  Status:    Active"))
    }
}
