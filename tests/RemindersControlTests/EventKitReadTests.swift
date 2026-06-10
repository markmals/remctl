import Testing
import Foundation
@testable import RemindersControl

@Suite struct EventKitReadTests {
    let off = Ansi(enabled: false)
    private func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }

    // ── validation (validate_eventkit_read_args) ──────────────────────────────

    @Test func listIdRejected() {
        #expect {
            try validateEventKitReadArgs(listId: 5, formatIsTable: false)
        } throws: { error in
            let e = error as? EventKitReadError
            return e?.exitCode == 2 && e?.code == "eventkit_read_unsupported"
                && e?.message.contains("cannot use RemCTL numeric list ids") == true
        }
    }

    @Test func tableFormatRejected() {
        #expect {
            try validateEventKitReadArgs(listId: nil, formatIsTable: true)
        } throws: { error in
            (error as? EventKitReadError)?.message.contains("does not support table output") == true
        }
    }

    @Test func showRequiresListName() {
        #expect {
            try validateEventKitReadArgs(listId: nil, formatIsTable: false, requiresListName: true, listName: nil)
        } throws: { error in
            (error as? EventKitReadError)?.message.contains("show requires a list name") == true
        }
        #expect(throws: Never.self) {
            try validateEventKitReadArgs(listId: nil, formatIsTable: false, requiresListName: true, listName: "Work")
        }
    }

    @Test func errorTextShapes() {
        let e = EventKitReadError("nope")
        let human = eventKitReadErrorText(e, json: false)
        #expect(human.hasPrefix("Error: nope\n"))
        #expect(human.contains("EventKit fallback note: eventKitId is not a RemCTL numeric id"))
        let json = eventKitReadErrorText(e, json: true)
        #expect(json.contains(#""code": "eventkit_read_unsupported""#))
        #expect(json.contains(#""source": "eventkit""#))
        #expect(json.contains(#""fidelity": "limited""#))
    }

    // ── payload shaping ───────────────────────────────────────────────────────

    @Test func itemJSONSanitizedKeys() throws {
        let c = cal()
        let due = c.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let item = EventKitItemSnapshot(eventKitId: "EK-1", externalId: "EXT-1", title: "Review PR",
                                        list: "Work", completed: false, priority: 1,
                                        notes: "soon", url: "https://x", dueDate: due, allDay: true)
        let obj = eventKitItemJSON(item, calendar: c)
        let keys = obj.map { $0.0 }
        #expect(keys == ["eventKitId", "title", "list", "completed", "priority", "externalId",
                         "notes", "url", "dueDate", "allDay", "createdDate"].filter { keys.contains($0) })
        #expect(!keys.contains("id"))
        #expect(obj.contains { $0.0 == "priority" && $0.1 == .string("high") })
        #expect(obj.contains { $0.0 == "allDay" && $0.1 == .bool(true) })
        #expect(obj.contains { $0.0 == "dueDate" && $0.1 == .string("2026-06-15T00:00:00") })
    }

    @Test func wrapperPayloadShape() throws {
        let payload = eventKitReadPayloadJSON(mode: "today", items: [
            EventKitItemSnapshot(eventKitId: "EK-1", title: "T", list: "Work"),
        ])
        let data = Data(payload.serialized(indent: 2, ensureAscii: false).utf8)
        let d = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((d?["source"] as? String) == "eventkit")
        #expect((d?["fidelity"] as? String) == "limited")
        #expect((d?["mode"] as? String) == "today")
        #expect((d?["idWarning"] as? String)?.contains("not a RemCTL numeric id") == true)
        #expect((d?["limitations"] as? [String])?.count == 6)
        let items = d?["items"] as? [[String: Any]]
        #expect((items?.first?["eventKitId"] as? String) == "EK-1")
        #expect(items?.first?["id"] == nil)
    }

    // ── human rendering ───────────────────────────────────────────────────────

    @Test func fmtItemBasicLine() {
        let item = EventKitItemSnapshot(eventKitId: "EK-XYZ", title: "Buy milk", list: "Groceries", priority: 1)
        let line = fmtEventKitItem(item, ansi: off)
        #expect(line == "[ ] !!! Buy milk EventKit ID: EK-XYZ")
    }

    @Test func fmtItemVerboseLines() {
        let item = EventKitItemSnapshot(eventKitId: "EK-XYZ", title: "Buy milk", list: "Groceries",
                                        notes: "2%", url: "https://x", allDay: true)
        let out = fmtEventKitItem(item, verbose: true, ansi: off)
        #expect(out.contains("    List: Groceries"))
        #expect(out.contains("    Notes: 2%"))
        #expect(out.contains("    URL: https://x"))
        #expect(out.contains("    All-day: Yes"))
    }

    @Test func renderNoticeHeadingAndCount() {
        let items = [EventKitItemSnapshot(eventKitId: "EK-1", title: "A", list: "L"),
                     EventKitItemSnapshot(eventKitId: "EK-2", title: "B", list: "L")]
        let out = renderEventKitRead(items: items, heading: "Work (EventKit limited)",
                                     emptyMessage: "none", ansi: off)
        #expect(out.hasPrefix("EventKit limited read fallback\n"))
        #expect(out.contains("Unavailable in this mode: No sections, No synced tags"))
        #expect(out.contains("Work (EventKit limited)"))
        #expect(out.hasSuffix("\n2 reminders\n"))
    }

    @Test func renderEmptyMessage() {
        let out = renderEventKitRead(items: [], heading: "H", emptyMessage: "Nothing via EventKit", ansi: off)
        #expect(out.contains("Nothing via EventKit"))
        #expect(!out.contains("0 reminders"))
    }

    @Test func renderGroupsByDayWithTodayLabel() {
        let c = cal()
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9))!
        let today = c.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 17))!
        let tomorrow = c.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 9))!
        let items = [
            EventKitItemSnapshot(eventKitId: "EK-2", title: "Later", list: "L", dueDate: tomorrow),
            EventKitItemSnapshot(eventKitId: "EK-1", title: "Soon", list: "L", dueDate: today),
        ]
        let out = renderEventKitRead(items: items, heading: "Upcoming", emptyMessage: "none",
                                     groupByDay: true, ansi: off, now: now, calendar: c)
        #expect(out.contains("  Today:"))
        #expect(out.contains("  Tomorrow:"))
        let todayIdx = out.range(of: "Today:")!.lowerBound
        let tomorrowIdx = out.range(of: "Tomorrow:")!.lowerBound
        #expect(todayIdx < tomorrowIdx)
    }

    // ── CLI-level validation (exits before any store or EventKit access) ──────

    @Test func cliShowViaEventKitRejectsListId() throws {
        let r = try CLIRunner.run(["show", "--via-eventkit", "--list-id", "3"])
        #expect(r.exit == 2)
        #expect(r.stderr.contains("cannot use RemCTL numeric list ids"))
    }

    @Test func cliShowViaEventKitRequiresListName() throws {
        let r = try CLIRunner.run(["show", "--via-eventkit"])
        #expect(r.exit == 2)
        #expect(r.stderr.contains("show requires a list name"))
    }

    @Test func cliTableRejectedJSONError() throws {
        let r = try CLIRunner.run(["today", "--via-eventkit", "--format", "table"])
        #expect(r.exit == 2)
        #expect(r.stderr.contains("does not support table output"))
    }
}
