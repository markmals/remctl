import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite struct AddTests {
    /// Build a fixture store. `build` seeds rows on a fresh Reminders schema.
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    /// A store with a 'Work' list (id 10, ckid 'CK-W') for resolution tests.
    private func withWorkList() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
        }
    }

    /// Extract the single recorded `.create` ReminderWrite, or fail.
    private func createdWrite(_ m: MockWriter, sourceLocation: SourceLocation = #_sourceLocation) -> ReminderWrite? {
        guard m.calls.count == 1, case let .create(w) = m.calls[0] else {
            Issue.record("expected exactly one .create call, got \(m.calls)", sourceLocation: sourceLocation)
            return nil
        }
        return w
    }

    // A fixed reference date so due parsing is deterministic.
    private var fixedNow: Date { Date(timeIntervalSince1970: 1_700_000_000) }  // 2023-11-14T...

    @Test func basicAddJSON() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(title: "Buy milk", json: true, store: s, writer: m, private: MockPrivateWriter())
        // Compact, key order status,id,title; numericId absent (no such row in fixture).
        #expect(out.stdout == #"{"status": "created", "id": "EK-NEW", "title": "Buy milk"}"# + "\n")
        #expect(out.exitCode == 0)
        let w = createdWrite(m)
        #expect(w?.title == "Buy milk")
        #expect(w?.due == nil)
    }

    @Test func basicAddHuman() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(title: "Buy milk", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.stdout == "Created: Buy milk\n")
        #expect(out.exitCode == 0)
        #expect(m.calls.count == 1)
    }

    @Test func dueParsedSetsWrite() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", due: "tomorrow", json: false, store: s, writer: m, private: MockPrivateWriter(), now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        let w = createdWrite(m)
        // The create call captured a non-nil .set(date) due.
        if case .set? = w?.due {} else { Issue.record("expected due == .set(date), got \(String(describing: w?.due))") }
    }

    @Test func badDueExitsTwoHuman() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", due: "notadate", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse due date"))
        #expect(m.calls.isEmpty)   // writer never reached
    }

    @Test func badDueExitsTwoJSON() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", due: "notadate", json: true, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 2)
        // JSON payload goes to stderr with the invalid_due_date code + input echo.
        #expect(out.stderr.contains(#""code": "invalid_due_date""#))
        #expect(out.stderr.contains(#""input": "notadate""#))
        #expect(out.stdout.isEmpty)
        #expect(m.calls.isEmpty)
    }

    @Test func priorityHigh() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", priority: "high", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.priority == 1)
    }

    @Test func badPriorityExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", priority: "bogus", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: priority must be high, medium, low, or none.\n")
        #expect(m.calls.isEmpty)
    }

    @Test func badRecurrenceExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", recurrence: "fortnightly", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("could not parse recurrence"))
        #expect(m.calls.isEmpty)
    }

    @Test func badAlarmExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", alarm: "soon", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: could not parse alarm 'soon'. Use 15m, 1h, 1d, or an absolute date.\n")
        #expect(m.calls.isEmpty)
    }

    @Test func recurrenceParses() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", recurrence: "daily", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(createdWrite(m)?.recurrence == RecurrenceWrite(frequency: "daily", interval: 1))
    }

    @Test func alarmParses() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", alarm: "15m", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(createdWrite(m)?.alarm == .relativeOffset(-900))
    }

    @Test func urlGoesToNotesAppendField() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", url: "https://x", json: false, store: s, writer: m, private: MockPrivateWriter())
        // Phase 2: --url sets ReminderWrite.url; the EventKitWriter appends it to notes.
        #expect(createdWrite(m)?.url == "https://x")
    }

    @Test func notesSet() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", notes: "remember", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(createdWrite(m)?.notes == "remember")
    }

    @Test func listResolutionAddsResolvedListJSON() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(title: "T", list: "work", json: true, store: s, writer: m, private: MockPrivateWriter())
        // Resolved list name flows into the write.
        #expect(createdWrite(m)?.list == "Work")
        // case-insensitive method != exact, so resolvedList is emitted.
        #expect(out.stdout.contains(#""resolvedList": {"#))
        #expect(out.stdout.contains(#""requested": "work""#))
        #expect(out.stdout.contains(#""title": "Work""#))
        #expect(out.stdout.contains(#""id": 10"#))
        #expect(out.stdout.contains(#""method": "case_insensitive""#))
    }

    @Test func listResolutionAddsResolvedListHuman() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", list: "work", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.stdout == "Created: T\nList: Work (resolved from work)\n")
    }

    @Test func exactListMatchOmitsResolvedList() async throws {
        let (s, dir) = try withWorkList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", list: "Work", json: false, store: s, writer: m, private: MockPrivateWriter())
        // Exact match: no "List:" line.
        #expect(out.stdout == "Created: T\n")
        #expect(createdWrite(m)?.list == "Work")
    }

    @Test func listNotFoundExitsOne() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", list: "Nope", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("list not found"))
        #expect(m.calls.isEmpty)   // resolution failed before write
    }

    @Test func urgentRoutesPrivate() async throws {
        // --urgent is a private-ONLY flag → wantsPrivate. The reminder is created via EventKit,
        // then setUrgent is called on the new ckid. --flag and --tags in the SAME command now also
        // route private (setFlagged / addPrivateMetadata) instead of their public proxies.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "T", url: "https://x", flag: true, tags: "work,home",
                                        urgent: true, json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        // Public proxies are NOT used when wantsPrivate: title keeps no #hashtags, write.flagged nil,
        // write.url nil.
        let w = createdWrite(m)
        #expect(w?.title == "T")
        #expect(w?.flagged == nil)
        #expect(w?.url == nil)
        // Private fan-out emission order: addPrivateMetadata, setFlagged, setUrgent.
        #expect(mp.calls == [
            .addPrivateMetadata(id: "EK-NEW", urls: ["https://x"], tags: ["work", "home"]),
            .setFlagged(id: "EK-NEW", flagged: true),
            .setUrgent(id: "EK-NEW", urgent: true),
        ])
        #expect(out.stdout == "Created: T\nPrivate metadata: applied 3 updates\n")
    }

    /// A Groceries list (pk 10, ckid CK-G) with a "Produce" section (ckid SEC-G). When
    /// `member` is given, that reminder ckid is seeded as a member of Produce (auto-sectioned).
    private func withGroceryList(member: String? = nil) throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZSHOULDCATEGORIZEGROCERYITEMS) VALUES (10,3,'Groceries',0,'CK-G',1)")
            try db.execute(sql: "INSERT INTO ZREMCDBASESECTION (Z_PK,Z_ENT,ZDISPLAYNAME,ZLIST,ZCKIDENTIFIER,ZMARKEDFORDELETION) VALUES (5,5,'Produce',10,'SEC-G',0)")
            if let member {
                let blob = #"{"memberships":[{"groupID":"SEC-G","memberID":"\#(member)"}]}"#
                try db.execute(sql: "UPDATE ZREMCDBASELIST SET ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA = ? WHERE Z_PK = 10", arguments: [blob])
            }
        }
    }

    @Test func groceryAutoSectionedSkipsHelper() async throws {
        // --grocery on a Groceries list, with the created reminder already auto-sectioned by
        // Reminders.app → reminders_auto, the private helper is NOT called.
        let (s, dir) = try withGroceryList(member: "GR-NEW"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "GR-NEW"
        let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "Milk", list: "Groceries", grocery: true, json: false,
                                        store: s, writer: m, private: mp, groceryAttempts: 1, groceryDelay: 0)
        #expect(out.exitCode == 0)
        #expect(mp.calls.isEmpty)                          // auto-sectioned → no helper call
        #expect(out.stdout.contains("Private metadata: applied 1 update"))
    }

    @Test func groceryNeedsHelperCallsCategorize() async throws {
        // --grocery on a Groceries list where the reminder is NOT auto-sectioned → the helper is
        // invoked with the list ckid + the new reminder ckid.
        let (s, dir) = try withGroceryList(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "GR-NEW"
        let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "Milk", list: "Groceries", grocery: true, json: false,
                                        store: s, writer: m, private: mp, groceryAttempts: 1, groceryDelay: 0)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.categorizeGroceryItems(listId: "CK-G", reminderIds: ["GR-NEW"])])
    }

    @Test func groceryNonGroceryListErrors() async throws {
        // --grocery on a NON-grocery list → require_grocery_list_target rejection (exit 1).
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "Milk", list: "Work", grocery: true, json: false, store: s, writer: m, private: mp, groceryAttempts: 1, groceryDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: target list 'Work' is not a Groceries list. Use `remctl list-edit ... --private --groceries` first.\n")
    }

    @Test func badDueBeatsGroceryFlag() async throws {
        // A bad due surfaces as exit 2 (due-validation runs before the post-create grocery fan-out).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", due: "notadate", grocery: true, json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse due date"))
        #expect(m.calls.isEmpty)
    }

    @Test func titleRequiredEmpty() async throws {
        // An empty title is rejected with the bridge's exact string (EventKitWriter.create
        // would throw the same), exit 1, writer never reached.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: title is required for create\n")
        #expect(m.calls.isEmpty)
    }

    @Test func whitespaceTitleIsAccepted() async throws {
        // Parity: the bridge uses raw `!title.isEmpty` (no trimming), so a whitespace-only
        // title is NOT rejected by the core; it flows through to the writer unchanged.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "   ", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.title == "   ")
    }

    @Test func badDueBeatsEmptyTitle() async throws {
        // Due-validation runs first: a bad due wins (exit 2) over the empty-title check.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "", due: "notadate", json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 2)
        #expect(out.stderr.contains("could not parse due date"))
        #expect(m.calls.isEmpty)
    }

    @Test func emptyTitleRejectedEvenWithGrocery() async throws {
        // --grocery is wired (P14) but its fan-out runs POST-create; the empty-title check fires
        // first (exit 1, writer never reached).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "", grocery: true, json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: title is required for create\n")
        #expect(m.calls.isEmpty)
    }

    @Test func numericIdReReadAppended() async throws {
        // When the created ZCKIDENTIFIER re-reads to a Z_PK, JSON gets numericId and human gets "ID: #".
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Home',0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (77,'Buy milk',10,1,0,'EK-NEW')")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let outH = try await Add.perform(title: "Buy milk", json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(outH.stdout == "Created: Buy milk\nID: #77\n")
        let m2 = MockWriter(); m2.resultID = "EK-NEW"
        let outJ = try await Add.perform(title: "Buy milk", json: true, store: s, writer: m2, private: MockPrivateWriter())
        #expect(outJ.stdout == #"{"status": "created", "id": "EK-NEW", "title": "Buy milk", "numericId": 77}"# + "\n")
    }

    // MARK: - P12: public/private imply-split

    @Test func flagAloneUsesPublicProxy() async throws {
        // --flag with NO private-only flag → PUBLIC: EventKit priority-proxy (write.flagged=true),
        // private writer NOT called.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "T", flag: true, json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.flagged == true)
        #expect(mp.calls.isEmpty)
    }

    @Test func tagsAloneAppendsHashtagsToTitle() async throws {
        // --tags with NO private-only flag → PUBLIC: inline #hashtag title-append; no priv call.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "Buy milk", tags: "work,home", json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.title == "Buy milk #work #home")
        #expect(out.stdout == "Created: Buy milk #work #home\n")
        #expect(mp.calls.isEmpty)
    }

    @Test func tagsAlreadyInTitleSkipped() async throws {
        // A tag whose #hashtag is already present in the title is NOT re-appended (cmd_add:5192).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        _ = try await Add.perform(title: "Task #done", tags: "#done", json: false, store: s, writer: m, private: mp)
        #expect(createdWrite(m)?.title == "Task #done")
        #expect(mp.calls.isEmpty)
    }

    @Test func tagsAndUrlRoutePrivateWhenWantsPrivate() async throws {
        // With a private-only flag (--urgent), --tags & --url route to addPrivateMetadata; the title
        // gets NO #hashtags and write.url stays nil.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"; let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "Buy milk", url: "https://x", tags: "work",
                                        urgent: true, json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.title == "Buy milk")   // no #hashtag append
        #expect(createdWrite(m)?.url == nil)
        #expect(mp.calls == [
            .addPrivateMetadata(id: "EK-NEW", urls: ["https://x"], tags: ["work"]),
            .setUrgent(id: "EK-NEW", urgent: true),
        ])
    }

    @Test func earlyReminderNoDueExitsOne() async throws {
        // --early-reminder 15m with NO due → exit 1 with the exact source message.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", earlyReminder: "15m", json: false, store: s, writer: m, private: mp)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Early Reminder requires a reminder due date.\n")
        #expect(m.calls.isEmpty)
        #expect(mp.calls.isEmpty)
    }

    @Test func earlyReminderWithDueSetsSpec() async throws {
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"; let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "T", due: "tomorrow", earlyReminder: "15m",
                                        json: false, store: s, writer: m, private: mp, now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.setEarlyReminder(id: "EK-NEW", spec: .set(unit: 0, count: -15, existingIdentifiers: []))])
    }

    @Test func earlyReminderClearNoDueOK() async throws {
        // `clear` is not a "set", so the due-date guard does NOT fire — it can clear with no due.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"; let mp = MockPrivateWriter()
        let out = try await Add.perform(title: "T", earlyReminder: "clear", json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.setEarlyReminder(id: "EK-NEW", spec: .clear(existingIdentifiers: []))])
    }

    @Test func privateJSONArrayPresentDefaultSpacing() async throws {
        // JSON mode: a "private" array of result objects, attached after numericId, DEFAULT spacing.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter(); mp.result = PrivateResult(status: "updated", fields: ["urgent": .bool(true)])
        let out = try await Add.perform(title: "T", urgent: true, json: true, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        // Each result obj is {status, <sorted fields>}; DEFAULT ": " / ", " spacing.
        #expect(out.stdout == #"{"status": "created", "id": "EK-NEW", "title": "T", "private": [{"status": "updated", "urgent": true}]}"# + "\n")
    }

    // MARK: - P13: subtasks + image attachments

    private func childResult(_ id: String, _ title: String) -> PrivateResult {
        PrivateResult(status: "updated", fields: ["subtasks": .array([
            .object([("id", .string(id)), ("title", .string(title)), ("url", .string("rem://\(id)"))])
        ])])
    }

    @Test func subtaskImpliesPrivateBareTitle() async throws {
        // --subtask "Buy milk" → wantsPrivate; addSubtasks(parent, [bare title]); no child writes.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "Buy milk")
        let out = try await Add.perform(title: "T", subtask: ["Buy milk"], json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.addSubtasks(id: "EK-NEW", subtasks: [SubtaskSpec(title: "Buy milk")])])
        // The parent create is the only public write — no child bridge update.
        #expect(m.calls == [.create(createdWriteValue(m))])
    }

    @Test func subtaskWithPublicFieldsDualWriter() async throws {
        // --subtask JSON with notes/due/priority → addSubtasks THEN child writer.update(C1, …).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "x")
        let json = #"{"title":"x","notes":"n","due":"tomorrow","priority":"high"}"#
        let out = try await Add.perform(title: "T", subtask: [json], json: false, store: s, writer: m, private: mp,
                                        now: fixedNow, calendar: .current)
        #expect(out.exitCode == 0)
        // Private writer: just the parent add_subtasks call.
        #expect(mp.calls.count == 1)
        // Public writer: parent create + one child update on "C1".
        #expect(m.calls.count == 2)
        guard case let .update(id, w) = m.calls[1] else { Issue.record("expected child update at calls[1]"); return }
        #expect(id == "C1")
        #expect(w.notes == "n")
        #expect(w.priority == 1)
        if case .set = w.due {} else { Issue.record("expected child due .set") }
    }

    @Test func subtaskWithPrivateChildFieldsDualWriter() async throws {
        // --subtask JSON with flagged/urgent/tags → child setFlagged/setUrgent/addPrivateMetadata.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "x")
        let json = #"{"title":"x","flagged":true,"urgent":true,"tags":"a,b"}"#
        let out = try await Add.perform(title: "T", subtask: [json], json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [
            .addSubtasks(id: "EK-NEW", subtasks: [SubtaskSpec(title: "x", tags: ["a", "b"], flagged: true, urgent: true)]),
            .addPrivateMetadata(id: "C1", urls: [], tags: ["a", "b"]),
            .setFlagged(id: "C1", flagged: true),
            .setUrgent(id: "C1", urgent: true),
        ])
        // No child public bridge fields → only the parent create on the public writer.
        #expect(m.calls.count == 1)
    }

    @Test func subtaskAddressRejected() async throws {
        // A subtask location address is unsupported → CLIError exit 1 before any write.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let json = #"{"title":"x","latitude":1,"longitude":2,"address":"1 Main St"}"#
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", subtask: [json], json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("address is not currently supported"))
        #expect(m.calls.isEmpty)
    }

    @Test func imageAttachmentsAdd() async throws {
        // --image is repeatable; paths are normalized (tilde-expanded) and passed to addAttachments.
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter()
        let home = NSHomeDirectory()
        let out = try await Add.perform(title: "T", image: ["~/a.png", "~/b.png"], json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(mp.calls == [.addAttachments(id: "EK-NEW", images: ["\(home)/a.png", "\(home)/b.png"])])
    }

    @Test func subtaskAndImageImplyPrivateFlagRoutesPrivate() async throws {
        // With --subtask present, a bare --flag now routes through the private writer (setFlagged),
        // NOT the EventKit priority-proxy (write.flagged stays nil on the create).
        let (s, dir) = try store { _ in }; defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let mp = MockPrivateWriter(); mp.subtasksResult = childResult("C1", "t")
        let out = try await Add.perform(title: "T", flag: true, subtask: ["t"], json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.flagged == nil)            // not the public proxy
        // Parent setFlagged appears after the add_subtasks (order: subtasks(4) → setFlagged(6)).
        #expect(mp.calls == [
            .addSubtasks(id: "EK-NEW", subtasks: [SubtaskSpec(title: "t")]),
            .setFlagged(id: "EK-NEW", flagged: true),
        ])
    }

    /// The recorded create ReminderWrite, for an exact `.create` equality assertion.
    private func createdWriteValue(_ m: MockWriter) -> ReminderWrite {
        for c in m.calls { if case let .create(w) = c { return w } }
        return ReminderWrite()
    }
}
