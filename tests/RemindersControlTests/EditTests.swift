import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct EditTests {
    /// Build a fixture store. `build` seeds rows on a fresh Reminders schema.
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A store with a 'Work' list (id 10) and reminder pk 42 (ckid 'ABC', title 'T', in Work).
    private func withReminder() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'T',10,1,0,0,'ABC')")
        }
    }

    /// Extract the single recorded `.update` ReminderWrite, or fail.
    private func updatedWrite(_ m: MockWriter, sourceLocation: SourceLocation = #_sourceLocation) -> (id: String, write: ReminderWrite)? {
        guard m.calls.count == 1, case let .update(id, w) = m.calls[0] else {
            Issue.record("expected exactly one .update call, got \(m.calls)", sourceLocation: sourceLocation)
            return nil
        }
        return (id, w)
    }

    // Fixed reference date for deterministic due parsing.
    private var fixedNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }  // 2023-11-14T...

    // MARK: - Title / basic

    @Test func editTitle() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, title: "New", json: false, store: s, writer: m)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Updated #42\n")
        let u = updatedWrite(m)
        #expect(u?.id == "ABC")
        #expect(u?.write.title == "New")
    }

    @Test func editTitleJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, title: "New", json: true, store: s, writer: m)
        #expect(out.exitCode == 0)
        #expect(out.stdout == #"{"status": "updated", "id": 42}"# + "\n")
    }

    // MARK: - Due

    @Test func dueClear() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, due: "clear", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.due == .clear)
    }

    @Test func dueSet() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, due: "tomorrow", json: false, store: s, writer: m, now: fixedNow, calendar: .current)
        if case .set? = updatedWrite(m)?.write.due {} else {
            Issue.record("expected due == .set(date), got \(String(describing: updatedWrite(m)?.write.due))")
        }
    }

    @Test func badDueExitsTwo() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, due: "notadate", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse due date"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - Double-tap nudge

    @Test func doubleTapNudge() async throws {
        // ZDUEDATE encodes a concrete instant; editing -d to the SAME instant fires the nudge.
        let cal = Calendar.current
        // Pick a clean local midnight so "today/tomorrow" math is irrelevant; we pass an ISO string.
        let instant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        let apple = AppleEpoch.toTs(instant)   // ZDUEDATE
        let iso: String = {
            let df = DateFormatter(); df.calendar = cal; df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = cal.timeZone; df.dateFormat = "yyyy-MM-dd HH:mm"; return df.string(from: instant)
        }()
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATE) VALUES (42,'T',10,1,0,0,'ABC',\(apple))")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, due: iso, json: false, store: s, writer: m, now: fixedNow, calendar: cal)
        #expect(out.exitCode == 0)
        // Two updates: first the nudge (instant + 1h), then the real update.
        #expect(m.calls.count == 2)
        if case let .update(_, nudge) = m.calls[0] {
            #expect(nudge.due == .set(instant.addingTimeInterval(3600)))
            #expect(nudge.title == nil)
        } else { Issue.record("first call should be the nudge update, got \(m.calls)") }
        if case let .update(_, real) = m.calls[1] {
            #expect(real.due == .set(instant))
        } else { Issue.record("second call should be the real update") }
    }

    // MARK: - List move

    @Test func listMove() async throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (11,3,'Home',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'T',11,1,0,0,'ABC')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, list: "work", json: false, store: s, writer: m)
        #expect(out.exitCode == 0)
        #expect(updatedWrite(m)?.write.list == "Work")
        #expect(out.stdout.contains("List: Work"))
    }

    @Test func listMoveJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        // Exact match -> "list" present, no resolvedList.
        let out = try await Edit.perform(id: 42, list: "Work", json: true, store: s, writer: m)
        #expect(out.stdout.contains(#""list": "Work""#))
        #expect(!out.stdout.contains("resolvedList"))
    }

    @Test func bothListAndId() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, list: "X", listId: 10, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either a list name or --list-id, not both.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - No changes

    @Test func noChanges() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, json: false, store: s, writer: m)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Nothing to update.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - Priority (no aliases)

    @Test func priorityNoAliasRejected() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, priority: "h", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: priority must be high, medium, low, or none.\n")
        #expect(m.calls.isEmpty)
    }

    @Test func priorityHigh() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, priority: "high", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.priority == 1)
    }

    // MARK: - Alarm

    @Test func alarmClearKeyword() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, alarm: "clear", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.alarm == .clear)
    }

    @Test func alarmRelative() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, alarm: "15m", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.alarm == .relativeOffset(-900))
    }

    @Test func badAlarmExitsOne() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, alarm: "soon", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: could not parse alarm 'soon'. Use 15m, 1h, 1d, an absolute date, or clear.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - Location alarm

    @Test func locationAlarm() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, latitude: 37.3, longitude: -122.0, json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.location == LocationAlarmWrite(title: nil, latitude: 37.3, longitude: -122.0, radius: 100.0, proximity: "arriving"))
    }

    @Test func locationLatWithoutLong() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, latitude: 37.3, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("latitude and longitude"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - Phase-3 stubs

    @Test func stubbedFlaggedErrorsPhase3() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, flagged: true, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Phase 3"))
        #expect(out.stderr.contains("--flagged"))
        #expect(m.calls.isEmpty)
    }

    @Test func stubbedUrgentErrorsPhase3() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, urgent: true, json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("Phase 3"))
        #expect(out.stderr.contains("--urgent"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - Resolution refusals

    @Test func notFound() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 999, title: "X", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: #999 not found\n")
        #expect(m.calls.isEmpty)
    }

    @Test func noIdentifierRefuses() async throws {
        // Reminder with no ZCKIDENTIFIER -> refusal mentioning "edit it".
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION) VALUES (42,'T',10,1,0,0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, title: "X", json: false, store: s, writer: m)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("no stable identifier"))
        #expect(out.stderr.contains("edit it"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - URL merge / notes gate

    @Test func urlAloneBecomesNotes() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, url: "https://x", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.notes == "https://x")
    }

    @Test func urlMergedIntoNotes() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, notes: "body", url: "https://x", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.notes == "body\n\nhttps://x")
    }

    @Test func emptyNotesStillSets() async throws {
        // notes gate is `!= nil`: an empty-string notes still sets notes (Python notes_body is not None).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, notes: "", json: false, store: s, writer: m)
        #expect(updatedWrite(m)?.write.notes == "")
    }

    // MARK: - Absolute-alarm carry / clear

    /// Build a date_components JSON blob for a Date in the calendar's TZ (what ZDATECOMPONENTSDATA holds).
    private func dateComponentsBlob(_ date: Date, calendar: Calendar) -> Data {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let obj: [String: Any] = [
            "year": c.year!, "month": c.month!, "day": c.day!,
            "hour": c.hour!, "minute": c.minute!, "second": c.second!,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func absoluteAlarmCarry() async throws {
        let cal = Calendar.current
        let oldInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        let oldApple = AppleEpoch.toTs(oldInstant)
        let blob = dateComponentsBlob(oldInstant, calendar: cal)
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATE) VALUES (42,'T',10,1,0,0,'ABC',\(oldApple))")
            // one absolute alarm: alarm object (Z_ENT=alarm) -> trigger object holding date_components.
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0)")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (81,?,0)", arguments: [blob])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        // New due tomorrow (no explicit --alarm) -> the matching absolute alarm should carry to new due.
        let newInstant = cal.date(from: DateComponents(year: 2024, month: 7, day: 10, hour: 14, minute: 30, second: 0))!
        let df = DateFormatter(); df.calendar = cal; df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = cal.timeZone; df.dateFormat = "yyyy-MM-dd HH:mm"
        _ = try await Edit.perform(id: 42, due: df.string(from: newInstant), json: false, store: s, writer: m, now: fixedNow, calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .set(newInstant))
        #expect(u?.write.alarm == .absolute(newInstant))
    }

    @Test func absoluteAlarmClearOnDueClear() async throws {
        let cal = Calendar.current
        let oldInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        let oldApple = AppleEpoch.toTs(oldInstant)
        let blob = dateComponentsBlob(oldInstant, calendar: cal)
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATE) VALUES (42,'T',10,1,0,0,'ABC',\(oldApple))")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0)")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (81,?,0)", arguments: [blob])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, due: "clear", json: false, store: s, writer: m, calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .clear)
        #expect(u?.write.alarm == .clear)
    }
}
