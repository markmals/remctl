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

    /// Rows as Reminders stored them live: a genuine at-due-time alarm (own ZALARMUID), then an
    /// EventKit location alarm saved as a time-interval/location pair sharing one ZALARMUID.
    @Test func locationAlarmCompanionRowIsHidden() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            ALTER TABLE ZREMCDOBJECT ADD COLUMN ZALARMUID TEXT;
            ALTER TABLE ZREMCDOBJECT ADD COLUMN ZALARM INTEGER;
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE) VALUES (42,'Both',1,1,0,0,980000000);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZALARMUID,ZMARKEDFORDELETION) VALUES
              (10,15,42,11,'AT-DUE',0), (12,15,42,13,'LOC',0), (14,15,42,15,'LOC',0);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZALARM,ZTIMEINTERVAL,ZMARKEDFORDELETION) VALUES (11,19,10,0,0), (13,19,12,0,0);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZALARM,ZTITLE,ZLATITUDE,ZLONGITUDE,ZRADIUS,ZPROXIMITY,ZMARKEDFORDELETION)
              VALUES (15,18,14,'Ocean',0.5,-140,100,1,0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let alarms = try #require(d?["alarms"] as? [[String: Any]])
        #expect(alarms.map { $0["id"] as? Int } == [10, 14])
        #expect(alarms.map { $0["type"] as? String } == ["relative", "location"])
    }

    @Test func alarmRowsWithoutAnAlarmUIDAreAllKept() {
        // Older stores have no ZALARMUID: the pairing can't be proven, so nothing is hidden.
        let rows = [DictRow(["alarm_id": 1, "time_interval": 0.0]),
                    DictRow(["alarm_id": 2, "latitude": 0.5, "longitude": -140.0])]
        #expect(alarmsWithoutLocationCompanions(rows).map { $0.int("alarm_id") } == [1, 2])
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
