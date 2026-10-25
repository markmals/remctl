import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// Gregorian calendar pinned to a named zone.
private func calendar(in zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

/// Apple-epoch seconds for a UTC wall time, the way Reminders stores timestamps.
private func utcApple(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Double {
    let c = calendar(in: "UTC")
    return AppleEpoch.toTs(c.date(from: DateComponents(year: year, month: month, day: day,
                                                       hour: hour, minute: minute))!)
}

private func appleIn(_ zone: String, _ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0) -> Double {
    let c = calendar(in: zone)
    return AppleEpoch.toTs(c.date(from: DateComponents(year: year, month: month, day: day,
                                                       hour: hour, minute: minute))!)
}

/// A reminder row with the columns `serializeReminder` always reads.
private func reminderRow(_ fields: [String: Any?]) -> DictRow {
    var values: [String: Any?] = [
        "Z_PK": 1, "ZTITLE": "x", "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0,
        "ZPRIORITY": 0, "ZPARENTREMINDER": 0,
    ]
    for (k, v) in fields { values[k] = v }
    return DictRow(values)
}

private func serialized(_ row: DictRow, zone: String,
                        hasAbsoluteAlarm: (() -> Bool)? = nil) -> [String: JSONValue] {
    let cal = calendar(in: zone)
    let pairs = serializeReminder(row, ts: { AppleEpoch.ts($0, calendar: cal) },
                                  priorityNames: Constants.priorityName,
                                  calendar: cal, hasAbsoluteAlarm: hasAbsoluteAlarm)
    return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) })
}

// ── Floating timed due dates (upstream 454d2c9, refined in 8f84a80; issue #49) ──

@Suite struct FloatingDueDateTests {
    /// Rows from issue #49, in New York on September 30 (UTC-4). Reminders.app stores an
    /// instant with a time zone; GoodTask stores 5 PM as 17:00Z with none; some rows carry a
    /// time zone but still hold wall-clock time.
    @Test func floatingTimedDueDateReadsAsWallClockTime() {
        let cases: [(String, [String: Any?], String)] = [
            ("instant", ["ZDUEDATE": utcApple(2026, 9, 30, 21), "ZDISPLAYDATEDATE": utcApple(2026, 9, 30, 21),
                         "ZTIMEZONE": "America/New_York"], "2026-09-30T17:00:00"),
            ("no time zone", ["ZDUEDATE": utcApple(2026, 9, 30, 17), "ZDISPLAYDATEDATE": utcApple(2026, 9, 30, 21),
                              "ZTIMEZONE": nil], "2026-09-30T17:00:00"),
            ("wall clock with a time zone", ["ZDUEDATE": utcApple(2026, 9, 30, 12),
                                             "ZDISPLAYDATEDATE": utcApple(2026, 9, 30, 16),
                                             "ZTIMEZONE": "America/New_York"], "2026-09-30T12:00:00"),
        ]
        for (name, fields, expected) in cases {
            let d = serialized(reminderRow(fields.merging(["ZALLDAY": 0]) { a, _ in a }), zone: "America/New_York")
            #expect(d["dueDate"]?.asString == expected, "\(name)")
            #expect(d["displayDate"] == nil, "\(name)")
        }
    }

    @Test func floatingDueDateEastOfUtc() {
        let d = serialized(reminderRow(["ZALLDAY": 0, "ZDUEDATE": utcApple(2026, 9, 30, 17), "ZTIMEZONE": nil]),
                           zone: "Europe/Rome")
        #expect(d["dueDate"]?.asString == "2026-09-30T17:00:00")
    }

    /// An alarm 15 minutes early is a display date, not a floating due date.
    @Test func alarmNearAnInstantIsNotAFloatingDueDate() {
        let d = serialized(reminderRow(["ZALLDAY": 0, "ZDUEDATE": utcApple(2026, 9, 30, 21),
                                        "ZDISPLAYDATEDATE": utcApple(2026, 9, 30, 20, 45),
                                        "ZTIMEZONE": "America/New_York"]), zone: "America/New_York")
        #expect(d["dueDate"]?.asString == "2026-09-30T17:00:00")
        #expect(d["displayDate"]?.asString == "2026-09-30T16:45:00")
    }

    /// A display date exactly one UTC offset from the due date is ambiguous: an absolute
    /// alarm proves it belongs to the alarm, so the zoned due time stays as stored.
    @Test func absoluteAlarmAtUtcOffsetKeepsZonedDueTime() {
        let cases: [(String, Double, Double, String, String)] = [
            ("Europe/Rome", utcApple(2026, 9, 30, 15), utcApple(2026, 9, 30, 13), "17:00:00", "15:00:00"),
            ("America/New_York", utcApple(2026, 9, 30, 17), utcApple(2026, 9, 30, 21), "13:00:00", "17:00:00"),
        ]
        for (zone, due, display, expectedDue, expectedDisplay) in cases {
            let d = serialized(reminderRow(["ZALLDAY": 0, "ZDUEDATE": due, "ZDISPLAYDATEDATE": display,
                                            "ZTIMEZONE": zone]), zone: zone, hasAbsoluteAlarm: { true })
            #expect(d["dueDate"]?.asString == "2026-09-30T\(expectedDue)", "\(zone)")
            #expect(d["displayDate"]?.asString == "2026-09-30T\(expectedDisplay)", "\(zone)")
        }
    }

    @Test func genuinelyFloatingRowStaysFloatingWithAnAlarm() {
        let d = serialized(reminderRow(["ZALLDAY": 0, "ZDUEDATE": utcApple(2026, 9, 30, 17),
                                        "ZDISPLAYDATEDATE": utcApple(2026, 9, 30, 21), "ZTIMEZONE": nil]),
                           zone: "America/New_York", hasAbsoluteAlarm: { true })
        #expect(d["dueDate"]?.asString == "2026-09-30T17:00:00")
        #expect(d["displayDate"] == nil)
    }

    /// At UTC both readings agree, so no alarm lookup is needed.
    @Test func noAlarmLookupWhenReadingsAgree() {
        var looked = false
        let d = serialized(reminderRow(["ZALLDAY": 0, "ZDUEDATE": utcApple(2026, 9, 30, 17),
                                        "ZDISPLAYDATEDATE": utcApple(2026, 9, 30, 17), "ZTIMEZONE": "UTC"]),
                           zone: "UTC", hasAbsoluteAlarm: { looked = true; return true })
        #expect(d["dueDate"]?.asString == "2026-09-30T17:00:00")
        #expect(!looked)
    }

    /// `remCols` selects ZTIMEZONE only when the store has it; an absent column must not
    /// read like a missing time zone and turn every timed reminder into a floating one.
    @Test func absentTimeZoneColumnIsNotAMissingTimeZone() {
        let d = serialized(reminderRow(["ZALLDAY": 0, "ZDUEDATE": utcApple(2026, 9, 30, 17)]),
                           zone: "America/New_York")
        #expect(d["dueDate"]?.asString == "2026-09-30T13:00:00")
    }

    @Test func timeZoneColumnSelectedOnlyWhenPresent() throws {
        let plain = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(!(try RemindersStore.open(storeDir: plain)).remCols().contains("ZTIMEZONE"))

        let zoned = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "ALTER TABLE ZREMCDREMINDER ADD COLUMN ZTIMEZONE TEXT")
        }
        defer { try? FileManager.default.removeItem(at: zoned) }
        #expect((try RemindersStore.open(storeDir: zoned)).remCols().contains("r.ZTIMEZONE"))
    }

    /// A store that has ZTIMEZONE serves floating rows through the full read path.
    @Test func floatingRowFromStoreReadsAsWallClockTime() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "ALTER TABLE ZREMCDREMINDER ADD COLUMN ZTIMEZONE TEXT")
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE,ZDISPLAYDATEDATE,ZTIMEZONE)
            VALUES (42,'Floating',1,1,0,0,0,\(utcApple(2026, 9, 30, 17)),\(utcApple(2026, 9, 30, 21)),NULL);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["dueDate"] as? String == "2026-09-30T17:00:00")
        #expect(d?["displayDate"] == nil)
    }

    @Test func absoluteAlarmLookupIgnoresDeletedAlarms() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (81,'{}',0);
            INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (82,\(Zent.alarm),43,83,1);
            INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (83,'{}',0);
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.hasAbsoluteAlarm(pk: 42))
        #expect(!store.hasAbsoluteAlarm(pk: 43))
        #expect(!store.hasAbsoluteAlarm(pk: 44))
    }
}

// ── All-day due dates in JSON (upstream e1a2618) ───────────────────────────────

@Suite struct AllDayDueDateTests {
    /// Reminders stores an all-day due date as midnight UTC and the display date as local
    /// midnight. Read as local time, midnight UTC is the evening before in New York.
    @Test func allDayDueDateKeepsItsDayInEveryTimeZone() {
        for zone in ["America/New_York", "Europe/Rome", "Asia/Tokyo"] {
            let d = serialized(reminderRow([
                "ZALLDAY": 1, "ZDUEDATE": utcApple(2026, 9, 30),
                "ZDISPLAYDATEDATE": appleIn(zone, 2026, 9, 30),
            ]), zone: zone)
            #expect(d["dueDate"]?.asString == "2026-09-30T00:00:00", "\(zone)")
            #expect(d["displayDate"] == nil, "\(zone)")
            #expect(d["allDay"]?.asBool == true, "\(zone)")
        }
    }

    @Test func allDayDueDateThatIsNotUTCMidnightKeepsItsLocalDay() {
        let d = serialized(reminderRow(["ZALLDAY": 1, "ZDUEDATE": appleIn("America/New_York", 2026, 9, 30, 8)]),
                           zone: "America/New_York")
        #expect(d["dueDate"]?.asString == "2026-09-30T00:00:00")
    }

    @Test func allDayDueDateThroughTheCLI() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE,ZDISPLAYDATEDATE)
            VALUES (42,'All day',1,1,0,0,1,\(utcApple(2026, 9, 30)),\(appleIn("America/New_York", 2026, 9, 30)));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["dueDate"] as? String == "2026-09-30T00:00:00")
        #expect(d?["displayDate"] == nil)
    }
}

// ── Bucketing by the date Reminders shows (upstream f9b6411) ───────────────────

@Suite struct ShownDateBucketingTests {
    /// A timed reminder whose absolute alarm kept the old time: Reminders lists it on the
    /// alarm's day, so today/overdue/upcoming have to bucket it there too.
    private func storeWithMovedDisplayDate() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE,ZDISPLAYDATEDATE)
            VALUES (42,'Write about Deflector',1,1,0,0,0,\(appleIn("America/New_York", 2026, 4, 23, 9)),\(appleIn("America/New_York", 2026, 4, 21, 15)));
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE,ZDISPLAYDATEDATE)
            VALUES (43,'Later',1,1,0,0,0,\(appleIn("America/New_York", 2026, 4, 23, 9)),\(appleIn("America/New_York", 2026, 4, 23, 9)));
            """)
        }
    }

    @Test func overdueFollowsTheDisplayDate() throws {
        let dir = try storeWithMovedDisplayDate()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let cal = calendar(in: "America/New_York")
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 12))!
        #expect(store.overdue(now: now).map { $0.int("Z_PK")! } == [42])
        #expect(store.dueToday(includeOverdue: true, now: now).map { $0.int("Z_PK")! } == [42])
        #expect(store.upcoming(days: 7, now: now).map { $0.int("Z_PK")! } == [43])
    }

    /// `today` runs against the real clock, so this fixture is relative to it: the due date
    /// is tomorrow, the alarm Reminders shows is yesterday.
    @Test func todayListsTheReminderByItsDisplayDate() throws {
        let cal = calendar(in: "America/New_York")
        let due = AppleEpoch.toTs(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
            .addingTimeInterval(9 * 3600))
        let shown = AppleEpoch.toTs(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
            .addingTimeInterval(15 * 3600))
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZALLDAY,ZDUEDATE,ZDISPLAYDATEDATE)
            VALUES (42,'Write about Deflector',1,1,0,0,0,\(due),\(shown));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let today = try CLIRunner.run(["today"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        #expect(today.stdout.contains("Overdue (1):"))
        #expect(today.stdout.contains("Write about Deflector"))
        let upcoming = try CLIRunner.run(["upcoming"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        #expect(!upcoming.stdout.contains("Write about Deflector"))
    }

    @Test func infoPrintsBothTimesWhenTheyDiffer() throws {
        let dir = try storeWithMovedDisplayDate()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        #expect(r.stdout.contains("Due:       Apr 23, 2026 at 09:00 AM"))
        #expect(r.stdout.contains("Shown at:  Apr 21, 2026 at 03:00 PM"))
        let same = try CLIRunner.run(["info", "43"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        #expect(!same.stdout.contains("Shown at:"))
    }

    @Test func jsonKeepsDueDateWithDisplayDateBesideIt() throws {
        let dir = try storeWithMovedDisplayDate()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir, extraEnv: ["TZ": "America/New_York"])
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["dueDate"] as? String == "2026-04-23T09:00:00")
        #expect(d?["displayDate"] as? String == "2026-04-21T15:00:00")
    }
}

// ── Early Reminder fallback table (upstream 088fab4, 0d8c208) ──────────────────

@Suite struct EarlyReminderFallbackTests {
    private static let alertID = "9F1C2F6E-0A27-4B6F-B0E8-6E3C9C1F77A1"
    private static let reminderCkid = "3C1D4E5F-6A7B-4C8D-9E0F-112233445566"

    private func storeWithDeltaAlertTable() throws -> URL {
        try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
            CREATE TABLE ZREMCDDUEDATEDELTAALERT (
              Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER BLOB, ZREMINDERIDENTIFIER BLOB,
              ZDUEDATEDELTAUNIT INTEGER, ZDUEDATEDELTACOUNT INTEGER, ZSORTORDER INTEGER,
              ZMINIMUMSUPPORTEDAPPVERSION INTEGER, ZCREATIONDATE REAL, ZACKNOWLEDGEDDATE REAL
            );
            INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'L',0);
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER)
            VALUES (42,'Pay rent',1,1,0,0,'\(Self.reminderCkid)');
            """)
            try db.execute(
                sql: "INSERT INTO ZREMCDDUEDATEDELTAALERT (Z_PK,ZIDENTIFIER,ZREMINDERIDENTIFIER,ZDUEDATEDELTAUNIT,ZDUEDATEDELTACOUNT,ZSORTORDER) VALUES (1,?,?,0,-15,0)",
                arguments: [uuidBytes(Self.alertID), uuidBytes(Self.reminderCkid)])
        }
    }

    private func uuidBytes(_ value: String) -> Data {
        withUnsafeBytes(of: UUID(uuidString: value)!.uuid) { Data($0) }
    }

    @Test func serializedPayloadFallsBackToTheAlertTable() throws {
        let dir = try storeWithDeltaAlertTable()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let payload = serializeReminders(store.reminders(limit: 10), store: store)[0]
        let d = Dictionary(uniqueKeysWithValues: payload.map { ($0.0, $0.1) })
        guard case let .object(first)? = d["earlyReminder"] else {
            Issue.record("earlyReminder missing"); return
        }
        let fields = Dictionary(uniqueKeysWithValues: first.map { ($0.0, $0.1) })
        #expect(fields["label"]?.asString == "15 minutes before")
        #expect(fields["identifier"]?.asString == Self.alertID)
    }

    @Test func identifiersForRemovalFallBackToTheAlertTable() throws {
        let dir = try storeWithDeltaAlertTable()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.earlyReminderIdentifiers(reminderCkid: Self.reminderCkid) == [Self.alertID])
    }

    /// The envelope blob still wins when it carries alerts.
    @Test func envelopeBlobTakesPrecedence() throws {
        let dir = try storeWithDeltaAlertTable()
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = try DatabaseQueue(path: dir.appendingPathComponent("Data-test.sqlite").path)
        try q.write { db in
            try db.execute(sql: "UPDATE ZREMCDREMINDER SET ZDUEDATEDELTAALERTSDATA = ? WHERE Z_PK = 42",
                           arguments: [#"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":2,"dueDateDeltaCount":-1,"identifier":"BLOB-1"}]}"#])
        }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.earlyReminderIdentifiers(reminderCkid: Self.reminderCkid) == ["BLOB-1"])
    }

    @Test func infoPrintsAndSerializesTheFallbackAlert() throws {
        let dir = try storeWithDeltaAlertTable()
        defer { try? FileManager.default.removeItem(at: dir) }
        let human = try CLIRunner.run(["info", "42"], storeDir: dir)
        #expect(human.stdout.contains("Early:     15 minutes before"))
        let r = try CLIRunner.run(["info", "42", "--json"], storeDir: dir)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let alerts = d?["earlyReminders"] as? [[String: Any]]
        #expect(alerts?.count == 1)
        #expect(alerts?.first?["label"] as? String == "15 minutes before")
    }

    @Test func verboseListingPrintsTheFallbackAlert() throws {
        let dir = try storeWithDeltaAlertTable()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["search", "Pay rent", "-v"], storeDir: dir)
        #expect(r.stdout.contains("Early: 15 minutes before"))
    }

    @Test func storeWithoutTheTableYieldsNoAlerts() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.earlyReminderAlerts(Self.reminderCkid).isEmpty)
    }
}
