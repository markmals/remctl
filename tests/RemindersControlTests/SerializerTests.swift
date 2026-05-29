import Testing
import Foundation
import GRDB
@testable import RemindersControl

// Test-only conveniences for asserting on ordered JSONValue payloads.
extension JSONValue {
    var asString: String? { if case let .string(s) = self { return s }; return nil }
    var asBool: Bool? { if case let .bool(b) = self { return b }; return nil }
    var asInt: Int? { if case let .int(i) = self { return i }; return nil }
}

/// Gregorian calendar pinned to Europe/Rome (matches the Python fixtures' local-time ISO output).
func romeCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Rome")!
    return c
}

@Suite struct OrderedJSONTests {
    @Test func preservesObjectKeyOrder() {
        let v = OrderedJSON.parse(Data(#"{"b":1,"a":2,"c":[3,4]}"#.utf8))!
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"b": 1, "a": 2, "c": [3, 4]}"#)
    }
    @Test func parsesNestedAndLiterals() {
        let v = OrderedJSON.parse(Data(#"{"x":{"y":true,"z":null},"w":"hi"}"#.utf8))!
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"x": {"y": true, "z": null}, "w": "hi"}"#)
    }
    @Test func rejectsTrailingGarbage() {
        #expect(OrderedJSON.parse(Data(#"{"a":1} x"#.utf8)) == nil)
    }
    @Test func allowsTrailingWhitespace() {
        #expect(OrderedJSON.parse(Data("{\"a\":1}\n  ".utf8)) != nil)
    }
}

@Suite struct RecurrenceTests {
    @Test func weeklyMonWed() {
        let row = DictRow([
            "recurrence_frequency": 1, "recurrence_interval": 1,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":4}]"#,
        ])
        let rec = recurrenceFromRow(row, ts: { AppleEpoch.ts($0) })!
        let s = JSONValue.object(rec).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"frequency": "weekly", "interval": 1, "daysOfWeekDetailed": [{"weekNumber": 0, "dayOfTheWeek": 2}, {"weekNumber": 0, "dayOfTheWeek": 4}], "daysOfWeek": [2, 4]}"#)
    }
    @Test func intervalZeroBecomesOne() {
        let row = DictRow(["recurrence_frequency": 2, "recurrence_interval": 0])
        let rec = recurrenceFromRow(row, ts: { AppleEpoch.ts($0) })!
        #expect(JSONValue.object(rec).serialized(indent: nil, ensureAscii: true) == #"{"frequency": "monthly", "interval": 1}"#)
    }
    @Test func noRecurrenceWhenFrequencyMissing() {
        #expect(recurrenceFromRow(DictRow([:]), ts: { AppleEpoch.ts($0) }) == nil)
    }
    @Test func earlyReminderBeforeLabel() {
        let row = DictRow(["ZDUEDATEDELTAALERTSDATA":
            #"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":0,"dueDateDeltaCount":-15,"identifier":"DELTA-1"}]}"#])
        let alerts = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        #expect(alerts.count == 1)
        let s = JSONValue.object(alerts[0]).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"unit": "minutes", "unitCode": 0, "count": -15, "value": 15, "direction": "before", "label": "15 minutes before", "identifier": "DELTA-1"}"#)
    }
    @Test func earlyReminderAfterWhenPositive() {
        let row = DictRow(["ZDUEDATEDELTAALERTSDATA": #"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":2,"dueDateDeltaCount":1}]}"#])
        let alerts = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        let s = JSONValue.object(alerts[0]).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"unit": "day", "unitCode": 2, "count": 1, "value": 1, "direction": "after", "label": "1 day after"}"#)
    }
    @Test func daysOfWeekAcceptsFloatDayValue() {
        let row = DictRow([
            "recurrence_frequency": 1, "recurrence_interval": 1,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":3.0}]"#,
        ])
        let rec = recurrenceFromRow(row, ts: { AppleEpoch.ts($0) })!
        let s = JSONValue.object(rec).serialized(indent: nil, ensureAscii: true)
        #expect(s.contains("\"daysOfWeek\": [3]"))
    }
}

@Suite struct ReminderSerializerTests {
    // Mirrors test_flagged_and_urgent_reminders_show_distinct_symbols_and_serialize
    @Test func baseKeysAndOrderWithDeepLink() {
        let row = DictRow([
            "Z_PK": 42, "ZTITLE": "Urgent flagged", "list_name": "Work",
            "ZCOMPLETED": 0, "ZFLAGGED": 1, "ZISURGENTSTATEENABLEDFORCURRENTUSER": 1,
            "ZPRIORITY": 0, "ZPARENTREMINDER": 0, "ZCKIDENTIFIER": "ABC",
        ])
        let obj = serializeReminder(row, ts: { AppleEpoch.ts($0) },
            priorityNames: Constants.priorityName, subtaskCounts: [42: 0], hashtags: [:])
        let s = JSONValue.object(obj).serialized(indent: 2, ensureAscii: true)
        #expect(s == """
        {
          "id": 42,
          "title": "Urgent flagged",
          "list": "Work",
          "completed": false,
          "flagged": true,
          "urgent": true,
          "priority": "none",
          "subtaskCount": 0,
          "isSubtask": false,
          "deepLink": "x-apple-reminderkit://REMCDReminder/ABC"
        }
        """)
    }
    // Mirrors test_info_json_keeps_due_date_separate_from_display_alarm_date
    @Test func dueDisplayAllDay() {
        let cal = romeCalendar()
        let row = DictRow([
            "Z_PK": 1, "ZTITLE": "x", "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0,
            "ZPRIORITY": 0, "ZPARENTREMINDER": 0, "ZDUEDATE": 801216000.0,
            "ZDISPLAYDATEDATE": 801215100.0, "ZALLDAY": 0,
        ])
        let obj = serializeReminder(row, ts: { AppleEpoch.ts($0, calendar: cal) },
            priorityNames: Constants.priorityName)
        let d = Dictionary(uniqueKeysWithValues: obj.map { ($0.0, $0.1) })
        #expect(d["dueDate"]?.asString == "2026-05-23T10:00:00")
        #expect(d["displayDate"]?.asString == "2026-05-23T09:45:00")
        #expect(d["allDay"]?.asBool == false)
    }
    @Test func nullTitleAndListBecomeJSONNull() {
        let row = DictRow(["Z_PK": 7, "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0, "ZPARENTREMINDER": 0])
        let obj = serializeReminder(row, ts: { AppleEpoch.ts($0) }, priorityNames: Constants.priorityName)
        let d = Dictionary(uniqueKeysWithValues: obj.map { ($0.0, $0.1) })
        #expect(d["title"]?.asString == nil)  // .null
        if case .null = d["title"]! {} else { Issue.record("title should be .null") }
    }
    @Test func displayDateOmittedWhenEqualToDue() {
        let row = DictRow(["Z_PK": 1, "ZTITLE": "x", "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0,
            "ZPRIORITY": 0, "ZPARENTREMINDER": 0, "ZDUEDATE": 801216000.0, "ZDISPLAYDATEDATE": 801216000.0])
        let obj = serializeReminder(row, ts: { AppleEpoch.ts($0) }, priorityNames: Constants.priorityName)
        #expect(!obj.contains { $0.0 == "displayDate" })
    }
    // serializeReminders end-to-end with a fixture store
    @Test func serializeRemindersBatchTagsAndSubtaskCount() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZMARKEDFORDELETION) VALUES (100,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION, ZCKIDENTIFIER) VALUES (1,'parent',100,1,0,0,'P');
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION, ZPARENTREMINDER) VALUES (2,'child',100,1,0,0,1);
            INSERT INTO ZREMCDHASHTAGLABEL (Z_PK, ZNAME) VALUES (50,'work');
            INSERT INTO ZREMCDOBJECT (Z_PK, ZREMINDER3, ZHASHTAGLABEL) VALUES (200,1,50);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        // Build the column fragment OUTSIDE the read block: remCols() probes columns via queue.read,
        // and GRDB read blocks are not reentrant.
        let cols = store.remCols()
        let fetched = try store.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.Z_PK = 1")
        }
        let objs = serializeReminders(fetched, store: store)
        let d = Dictionary(uniqueKeysWithValues: objs[0].map { ($0.0, $0.1) })
        #expect(d["subtaskCount"]?.asInt == 1)         // one active child
        if case let .array(tags)? = d["tags"] { #expect(tags.count == 1) } else { Issue.record("tags missing") }
    }
}
