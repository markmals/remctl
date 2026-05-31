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
        let out = try await Edit.perform(id: 42, title: "New", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Updated #42\n")
        let u = updatedWrite(m)
        #expect(u?.id == "ABC")
        #expect(u?.write.title == "New")
    }

    @Test func editTitleJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, title: "New", json: true, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(out.stdout == #"{"status": "updated", "id": 42}"# + "\n")
    }

    // MARK: - Due

    @Test func dueClear() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, due: "clear", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.due == .clear)
    }

    @Test func dueSet() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, due: "tomorrow", json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        if case .set? = updatedWrite(m)?.write.due {} else {
            Issue.record("expected due == .set(date), got \(String(describing: updatedWrite(m)?.write.due))")
        }
    }

    @Test func badDueExitsTwo() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, due: "notadate", json: false, store: s, writer: m, private: MockPrivateWriter())
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
        let out = try await Edit.perform(id: 42, due: iso, json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
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
        let out = try await Edit.perform(id: 42, list: "work", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(updatedWrite(m)?.write.list == "Work")
        #expect(out.stdout.contains("List: Work"))
    }

    @Test func listMoveJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        // Exact match -> "list" present, no resolvedList.
        let out = try await Edit.perform(id: 42, list: "Work", json: true, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.stdout.contains(#""list": "Work""#))
        #expect(!out.stdout.contains("resolvedList"))
    }

    @Test func bothListAndId() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, list: "X", listId: 10, json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either a list name or --list-id, not both.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - No changes

    @Test func noChanges() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(id: 42, json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Nothing to update.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - Priority (no aliases)

    @Test func priorityNoAliasRejected() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, priority: "h", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: priority must be high, medium, low, or none.\n")
        #expect(m.calls.isEmpty)
    }

    @Test func priorityHigh() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, priority: "high", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.priority == 1)
    }

    // MARK: - Alarm

    @Test func alarmClearKeyword() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, alarm: "clear", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.alarm == .clear)
    }

    @Test func alarmRelative() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, alarm: "15m", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.alarm == .relativeOffset(-900))
    }

    @Test func badAlarmExitsOne() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, alarm: "soon", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: could not parse alarm 'soon'. Use 15m, 1h, 1d, an absolute date, or clear.\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - Location alarm

    @Test func locationAlarm() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, latitude: 37.3, longitude: -122.0, json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.location == LocationAlarmWrite(title: nil, latitude: 37.3, longitude: -122.0, radius: 100.0, proximity: "arriving"))
    }

    @Test func locationLatWithoutLong() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, latitude: 37.3, json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("latitude and longitude"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - Private-only edits (P12)

    @Test func flaggedRoutesPrivateOnly() async throws {
        // --flagged is private-only and changes no editable field → private-ONLY branch: no EventKit
        // update, just setFlagged. Human output prints the private summary line.
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, flagged: true, json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(m.calls.isEmpty)                                    // no editable change → no update
        #expect(mp.calls == [.setFlagged(id: "ABC", flagged: true)])
        #expect(out.stdout == "Updated #42\nPrivate metadata: applied 1 update\n")
    }

    @Test func unflaggedRoutesPrivateOnly() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        _ = try await Edit.perform(id: 42, flagged: false, json: false, store: s, writer: m, private: mp)
        #expect(mp.calls == [.setFlagged(id: "ABC", flagged: false)])
    }

    @Test func urgentRoutesPrivateOnly() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, urgent: true, json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(m.calls.isEmpty)
        #expect(mp.calls == [.setUrgent(id: "ABC", urgent: true)])
    }

    @Test func privateOnlyJSONUsesIndentTwo() async throws {
        // cmd_edit:5584 quirk: the private-ONLY branch emits indent=2 JSON (vs no-indent main path).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, flagged: true, json: true, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("\n  \"status\": \"updated\"")) // indent=2, two-space pad
        #expect(out.stdout.contains(#""private": ["#))
    }

    @Test func editTagsRoutesPrivate() async throws {
        // edit --tags has no public fallback (cmd_edit:5417) → always routes addPrivateMetadata.
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        _ = try await Edit.perform(id: 42, tags: "a,b", json: false, store: s, writer: m, private: mp)
        #expect(mp.calls == [.addPrivateMetadata(id: "ABC", urls: [], tags: ["a", "b"])])
        #expect(m.calls.isEmpty)
    }

    @Test func sectionRoutesPrivateOnly() async throws {
        // --section is private-only and resolves against the reminder's current list (ZLIST=10).
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDBASESECTION (Z_PK,Z_ENT,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (1,5,'Errands',10,'SEC-1',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'T',10,1,0,0,'ABC')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        _ = try await Edit.perform(id: 42, section: "Errands", json: false, store: s, writer: m, private: mp)
        #expect(mp.calls == [.assignSection(id: "ABC", sectionId: "SEC-1")])
        #expect(m.calls.isEmpty)
    }

    @Test func newSectionRoutesPrivateOnly() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        _ = try await Edit.perform(id: 42, newSection: "Inbox", json: false, store: s, writer: m, private: mp)
        #expect(mp.calls == [.addSectionAndAssign(id: "ABC", name: "Inbox")])
    }

    @Test func earlyReminderNoDueExitsOne() async throws {
        // reminder 42 has no ZDUEDATE and no new due → guard fires (cmd_edit:5468).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, earlyReminder: "15m", json: false, store: s, writer: m, private: mp)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Early Reminder requires a reminder due date.\n")
        #expect(m.calls.isEmpty)
        #expect(mp.calls.isEmpty)
    }

    @Test func earlyReminderWithExistingDueOK() async throws {
        // reminder has an existing ZDUEDATE → the guard passes even with no new --due.
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATE) VALUES (42,'T',10,1,0,0,'ABC',700000000.0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, earlyReminder: "15m", json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.setEarlyReminder(id: "ABC", spec: .set(unit: 0, count: -15, existingIdentifiers: []))])
    }

    @Test func earlyReminderClearWithDueExitsOne() async throws {
        // Clearing the due (-d clear) while requesting a non-clear early-reminder → guard fires.
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATE) VALUES (42,'T',10,1,0,0,'ABC',700000000.0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, due: "clear", earlyReminder: "15m", json: false, store: s, writer: m, private: mp)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Early Reminder requires a reminder due date.\n")
    }

    @Test func editWithEditableChangeAndPrivateBothFire() async throws {
        // A public field change (title) AND a private flag (--flagged): EventKit update runs, then
        // the private fan-out, and the JSON attaches "private" after id (no-indent main path).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Edit.perform(id: 42, title: "New", flagged: true, json: true, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(m.calls.count == 1)   // the EventKit update fired
        #expect(mp.calls == [.setFlagged(id: "ABC", flagged: true)])
        #expect(out.stdout == #"{"status": "updated", "id": 42, "private": [{"status": "updated"}]}"# + "\n")
    }

    // MARK: - Resolution refusals

    @Test func notFound() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 999, title: "X", json: false, store: s, writer: m, private: MockPrivateWriter())
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
            try await Edit.perform(id: 42, title: "X", json: false, store: s, writer: m, private: MockPrivateWriter())
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
        _ = try await Edit.perform(id: 42, url: "https://x", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.notes == "https://x")
    }

    @Test func urlMergedIntoNotes() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, notes: "body", url: "https://x", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(updatedWrite(m)?.write.notes == "body\n\nhttps://x")
    }

    @Test func emptyNotesStillSets() async throws {
        // notes gate is `!= nil`: an empty-string notes still sets notes (Python notes_body is not None).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Edit.perform(id: 42, notes: "", json: false, store: s, writer: m, private: MockPrivateWriter())
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
        _ = try await Edit.perform(id: 42, due: df.string(from: newInstant), json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
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
        _ = try await Edit.perform(id: 42, due: "clear", json: false, store: s, writer: m, private: MockPrivateWriter(), calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .clear)
        #expect(u?.write.alarm == .clear)
    }

    // MARK: - Negative carry/clear: prove NO carry happens when a gate fails.
    //
    // The carry gate is: !explicitAlarm && newDue && oldDue && exactly-one-alarm &&
    // that-alarm-is-absolute && alarm == oldDue (to the second). Each test below trips
    // exactly one condition false and asserts `write.alarm == nil` (no carry was injected).

    /// Seed a reminder pk 42 (ckid 'ABC', list Work id 10) with ZDUEDATE = oldInstant.
    /// Returns the store + temp dir + a formatter producing "yyyy-MM-dd HH:mm" in the cal TZ.
    private func reminderWithDue(_ oldInstant: Date, calendar cal: Calendar,
                                 seedAlarms: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let oldApple = AppleEpoch.toTs(oldInstant)
        return try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZDUEDATE) VALUES (42,'T',10,1,0,0,'ABC',\(oldApple))")
            try seedAlarms(db)
        }
    }

    private func ymdhm(_ date: Date, _ cal: Calendar) -> String {
        let df = DateFormatter(); df.calendar = cal; df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = cal.timeZone; df.dateFormat = "yyyy-MM-dd HH:mm"; return df.string(from: date)
    }

    /// TWO absolute alarms both == old due. Gate requires exactly ONE alarm -> no carry.
    @Test func carrySuppressedByTwoAlarms() async throws {
        let cal = Calendar.current
        let oldInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        let blob = dateComponentsBlob(oldInstant, calendar: cal)
        let (s, dir) = try reminderWithDue(oldInstant, calendar: cal) { db in
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0)")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (81,?,0)", arguments: [blob])
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (82,\(Zent.alarm),42,83,0)")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (83,?,0)", arguments: [blob])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let newInstant = cal.date(from: DateComponents(year: 2024, month: 7, day: 10, hour: 14, minute: 30, second: 0))!
        _ = try await Edit.perform(id: 42, due: ymdhm(newInstant, cal), json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .set(newInstant))
        #expect(u?.write.alarm == nil)
    }

    /// One RELATIVE alarm (ZTIMEINTERVAL set). Gate requires an absolute alarm -> no carry.
    @Test func carrySuppressedByRelativeAlarm() async throws {
        let cal = Calendar.current
        let oldInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        let (s, dir) = try reminderWithDue(oldInstant, calendar: cal) { db in
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0)")
            // ZTIMEINTERVAL set -> serialized as type "relative".
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZTIMEINTERVAL,ZMARKEDFORDELETION) VALUES (81,-900,0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let newInstant = cal.date(from: DateComponents(year: 2024, month: 7, day: 10, hour: 14, minute: 30, second: 0))!
        _ = try await Edit.perform(id: 42, due: ymdhm(newInstant, cal), json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .set(newInstant))
        #expect(u?.write.alarm == nil)
    }

    /// One absolute alarm NOT equal to old due. Gate requires alarm == oldDue -> no carry.
    @Test func carrySuppressedByNonMatchingAlarm() async throws {
        let cal = Calendar.current
        let oldInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        // Alarm at a different instant than the reminder's due date.
        let alarmInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 8, minute: 0, second: 0))!
        let blob = dateComponentsBlob(alarmInstant, calendar: cal)
        let (s, dir) = try reminderWithDue(oldInstant, calendar: cal) { db in
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0)")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (81,?,0)", arguments: [blob])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let newInstant = cal.date(from: DateComponents(year: 2024, month: 7, day: 10, hour: 14, minute: 30, second: 0))!
        _ = try await Edit.perform(id: 42, due: ymdhm(newInstant, cal), json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .set(newInstant))
        #expect(u?.write.alarm == nil)
    }

    /// One absolute alarm == old due, but an EXPLICIT --alarm is also given.
    /// explicitAlarm short-circuits the carry branch entirely; the explicit alarm wins.
    @Test func carrySuppressedByExplicitAlarm() async throws {
        let cal = Calendar.current
        let oldInstant = cal.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 9, minute: 0, second: 0))!
        let blob = dateComponentsBlob(oldInstant, calendar: cal)
        let (s, dir) = try reminderWithDue(oldInstant, calendar: cal) { db in
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,Z_ENT,ZREMINDER,ZTRIGGER,ZMARKEDFORDELETION) VALUES (80,\(Zent.alarm),42,81,0)")
            try db.execute(sql: "INSERT INTO ZREMCDOBJECT (Z_PK,ZDATECOMPONENTSDATA,ZMARKEDFORDELETION) VALUES (81,?,0)", arguments: [blob])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let newInstant = cal.date(from: DateComponents(year: 2024, month: 7, day: 10, hour: 14, minute: 30, second: 0))!
        _ = try await Edit.perform(id: 42, due: ymdhm(newInstant, cal), alarm: "30m", json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
        let u = updatedWrite(m)
        #expect(u?.write.due == .set(newInstant))
        // The explicit --alarm 30m (relative, -1800s) wins; carry does NOT override it.
        #expect(u?.write.alarm == .relativeOffset(-1800))
    }

    // MARK: - Proximity choice (parse-time, like argparse choices)

    /// Valid --proximity values map to the writer's lowercase strings (arriving/leaving),
    /// which EventKitWriter turns into .enter/.leave respectively.
    @Test func proximityValuesMap() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m1 = MockWriter()
        _ = try await Edit.perform(id: 42, latitude: 37.3, longitude: -122.0, proximity: .leaving, json: false, store: s, writer: m1, private: MockPrivateWriter())
        #expect(updatedWrite(m1)?.write.location?.proximity == "leaving")

        let (s2, dir2) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir2) }
        let m2 = MockWriter()
        _ = try await Edit.perform(id: 42, latitude: 37.3, longitude: -122.0, proximity: .arriving, json: false, store: s2, writer: m2, private: MockPrivateWriter())
        #expect(updatedWrite(m2)?.write.location?.proximity == "arriving")
    }

    /// An invalid --proximity is rejected at the ArgumentParser layer BEFORE any core/DB access,
    /// mirroring Python argparse `choices=["arriving","leaving"]`. Note: ArgumentParser surfaces
    /// usage errors as EX_USAGE (64) uniformly across the whole port (e.g. `export --format bogus`
    /// also exits 64), whereas Python's argparse uses 2 — that numeric divergence is a framework
    /// trait of the Swift port, not specific to this option. The constraint itself is enforced:
    /// the error names the valid choices and no write/DB call occurs.
    @Test func invalidProximityRejected() throws {
        let r = try CLIRunner.run(["edit", "42", "--proximity", "foo"])
        #expect(r.exit == 64)
        #expect(r.stderr.contains("'--proximity"))
        #expect(r.stderr.contains("arriving"))
        #expect(r.stderr.contains("leaving"))
    }

    // MARK: - failInvalidDueDate forwards now/calendar (deterministic example date)

    /// The exit-2 invalid-due payload interpolates `today` from the injected `now`, not the
    /// real clock. With now = 2023-11-14 (fixedNow), the first example must be "2023-11-14 15:00".
    @Test func badDueUsesInjectedNowForExamples() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, due: "notadate", json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: cal)
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("2023-11-14 15:00"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - Validation/list-resolution precedence (mirrors cmd_edit source order)

    /// cmd_edit resolves the list move (remctl:5425-5436) BEFORE due validation (remctl:5461).
    /// So the both-list runtime check (exit 1) wins over a bad due (exit 2) on the same input.
    @Test func bothListWinsOverBadDuePrecedence() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, list: "X", listId: 10, due: "notadate", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either a list name or --list-id, not both.\n")
        #expect(m.calls.isEmpty)
    }

    /// Likewise list-not-found (exit 1) wins over a bad due (exit 2): list resolution runs first.
    @Test func listNotFoundWinsOverBadDuePrecedence() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, list: "Nonexistent", due: "notadate", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("list not found"))
        #expect(m.calls.isEmpty)
    }

    // MARK: - P13: subtasks + image attachments

    private func childResult(_ id: String, _ title: String) -> PrivateResult {
        PrivateResult(status: "updated", fields: ["subtasks": .array([
            .object([("id", .string(id)), ("title", .string(title)), ("url", .string("rem://\(id)"))])
        ])])
    }

    @Test func editSubtaskBareTitleImpliesPrivate() async throws {
        // --subtask on edit implies private; no other editable change → private-ONLY branch.
        // addSubtasks runs on the resolved ckid; no child writes for a bare title.
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "step 1")
        let out = try await Edit.perform(id: 42, subtask: ["step 1"], json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.addSubtasks(id: "ABC", subtasks: [SubtaskSpec(title: "step 1")])])
        #expect(m.calls.isEmpty)   // private-only branch, no public child bridge fields
    }

    @Test func editSubtaskWithPublicFieldsDualWriter() async throws {
        // A subtask carrying public fields makes the public writer fire for the CHILD even in the
        // edit private-only branch (no parent editable change).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "x")
        let json = #"{"title":"x","notes":"n","priority":"low"}"#
        let out = try await Edit.perform(id: 42, subtask: [json], json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls.count == 1)                          // just add_subtasks
        #expect(m.calls.count == 1)                           // child bridge update only
        guard case let .update(id, w) = m.calls[0] else { Issue.record("expected child update"); return }
        #expect(id == "C1")
        #expect(w.notes == "n")
        #expect(w.priority == 9)                              // low → 9
    }

    @Test func editSubtaskWithPrivateChildFields() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "x")
        let json = #"{"title":"x","flagged":true,"tags":"a,b"}"#
        _ = try await Edit.perform(id: 42, subtask: [json], json: false, store: s, writer: m, private: mp)
        #expect(mp.calls == [
            .addSubtasks(id: "ABC", subtasks: [SubtaskSpec(title: "x", tags: ["a", "b"], flagged: true)]),
            .addPrivateMetadata(id: "C1", urls: [], tags: ["a", "b"]),
            .setFlagged(id: "C1", flagged: true),
        ])
        #expect(m.calls.isEmpty)
    }

    @Test func editSubtaskAddressRejected() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let json = #"{"title":"x","latitude":1,"longitude":2,"address":"1 Main St"}"#
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, subtask: [json], json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("address is not currently supported"))
        #expect(m.calls.isEmpty)
    }

    @Test func editImageAttachments() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let home = NSHomeDirectory()
        _ = try await Edit.perform(id: 42, image: ["~/a.png"], json: false, store: s, writer: m, private: mp)
        #expect(mp.calls == [.addAttachments(id: "ABC", images: ["\(home)/a.png"])])
        #expect(m.calls.isEmpty)
    }

    @Test func editAddressStillRejected() async throws {
        // --address remains phase3-guarded in edit (P14 location work).
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Edit.perform(id: 42, address: "1 Main St", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("--address"))
        #expect(m.calls.isEmpty)
    }
}
