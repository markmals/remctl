import Testing
import Foundation
@testable import RemindersControl

@Suite struct TableTests {
    let plain = Ansi(enabled: false)

    // Helper: visible length using the module's stripper.
    private func vlen(_ s: String) -> Int { visibleLength(s) }

    // ── fmtTable structure ────────────────────────────────────────────────

    @Test func emptyReturnsEmptyString() {
        #expect(fmtTable([], maxWidth: 80) == "")
    }

    @Test func basicTableStructure() {
        let row = TableRow(id: "#1", title: "Buy milk", list: "Groceries",
                           due: "Today", repeatText: "", pri: "")
        let out = fmtTable([row], maxWidth: 80)
        #expect(out.hasPrefix("┌"))
        #expect(out.hasSuffix("┘"))
        for header in ["ID", "Title", "List", "Due", "Pri"] {
            #expect(out.contains(header))
        }
        #expect(out.contains("Buy milk"))
        // Header separator line uses the cross/tee glyphs.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sep = lines[2]
        #expect(sep.hasPrefix("├"))
        #expect(sep.contains("┼"))
        #expect(sep.hasSuffix("┤"))
        // Well-formed box: every line has equal visible length.
        let widths = Set(lines.map { vlen($0) })
        #expect(widths.count == 1)
    }

    @Test func repeatColumnOnlyWhenPresent() {
        let noRepeat = TableRow(id: "#1", title: "T", list: "L", due: "", repeatText: "", pri: "")
        #expect(!fmtTable([noRepeat], maxWidth: 80).contains("Repeat"))

        let withRepeat = TableRow(id: "#1", title: "T", list: "L", due: "", repeatText: "weekly", pri: "")
        #expect(fmtTable([withRepeat], maxWidth: 80).contains("Repeat"))
    }

    @Test func truncationAddsEllipsis() {
        let longTitle = "This is an extremely long reminder title that should get truncated"
        let row = TableRow(id: "#1", title: longTitle, list: "L", due: "", repeatText: "", pri: "")
        let out = fmtTable([row], maxWidth: 30)
        #expect(out.contains("…"))
        // Source caps only the Title column (to max(10, maxWidth-fixed)); it does NOT
        // cap total table width. With these narrow side columns the cap is 10, so the
        // truncated title cell renders as "This is a…" (9 chars + ellipsis).
        #expect(out.contains("This is a…"))
        // Every line is still a well-formed box: equal visible length across lines.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Set(lines.map { vlen($0) }).count == 1)
    }

    // ── Byte-equality against Python fmt_table (import oracle, uncolored) ───

    @Test func bytesMatchPythonBasic() {
        let row = TableRow(id: "#1", title: "Buy milk", list: "Groceries",
                           due: "Today", repeatText: "", pri: "")
        let expected = """
        ┌────┬──────────┬───────────┬───────┬─────┐
        │ ID │ Title    │ List      │ Due   │ Pri │
        ├────┼──────────┼───────────┼───────┼─────┤
        │ #1 │ Buy milk │ Groceries │ Today │     │
        └────┴──────────┴───────────┴───────┴─────┘
        """
        #expect(fmtTable([row], maxWidth: 80) == expected)
    }

    @Test func bytesMatchPythonWithRepeat() {
        let row = TableRow(id: "#1", title: "Buy milk", list: "Groceries",
                           due: "Today", repeatText: "weekly", pri: "!!")
        let expected = """
        ┌────┬──────────┬───────────┬───────┬────────┬─────┐
        │ ID │ Title    │ List      │ Due   │ Repeat │ Pri │
        ├────┼──────────┼───────────┼───────┼────────┼─────┤
        │ #1 │ Buy milk │ Groceries │ Today │ weekly │ !!  │
        └────┴──────────┴───────────┴───────┴────────┴─────┘
        """
        #expect(fmtTable([row], maxWidth: 80) == expected)
    }

    @Test func bytesMatchPythonTruncated() {
        let longTitle = "This is an extremely long reminder title that should get truncated"
        let row = TableRow(id: "#1", title: longTitle, list: "L", due: "", repeatText: "", pri: "")
        let expected = """
        ┌────┬────────────┬──────┬─────┬─────┐
        │ ID │ Title      │ List │ Due │ Pri │
        ├────┼────────────┼──────┼─────┼─────┤
        │ #1 │ This is a… │ L    │     │     │
        └────┴────────────┴──────┴─────┴─────┘
        """
        #expect(fmtTable([row], maxWidth: 30) == expected)
    }

    // ── visibleLength / stripAnsi ──────────────────────────────────────────

    @Test func visibleLengthStripsAnsi() {
        let colored = "\u{1B}[31mABC\u{1B}[0m"
        #expect(visibleLength(colored) == 3)
        #expect(stripAnsi(colored) == "ABC")
    }

    @Test func coloredCellsStillAlign() {
        let color = Ansi(enabled: true)
        let row = TableRow(id: color.cyan("#1"), title: "Buy milk", list: color.cyan("Groceries"),
                           due: color.red("Overdue 2d"), repeatText: "", pri: color.red("!!!"))
        let out = fmtTable([row], maxWidth: 80)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let widths = Set(lines.map { vlen($0) })
        #expect(widths.count == 1)
    }

    // ── remindersToTableData ───────────────────────────────────────────────

    // Pin "now" to a known instant: 2026-05-29 12:00 local.
    private var pinnedNow: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 29; c.hour = 12; c.minute = 0; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func appleSeconds(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Double {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = 0
        let date = Calendar.current.date(from: c)!
        return date.timeIntervalSince1970 - AppleEpoch.offset
    }

    @Test func remindersToTableDataDueStrings() {
        let now = pinnedNow
        // Today (no time) → "Today"
        let today = DictRow(["Z_PK": 1, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0,
                             "list_name": "L", "ZDUEDATE": appleSeconds(year: 2026, month: 5, day: 29)])
        // Tomorrow
        let tomorrow = DictRow(["Z_PK": 2, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0,
                                "list_name": "L", "ZDUEDATE": appleSeconds(year: 2026, month: 5, day: 30)])
        // Overdue 2d (2026-05-27 12:00 is exactly 2 days before now)
        let overdue = DictRow(["Z_PK": 3, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0,
                               "list_name": "L", "ZDUEDATE": appleSeconds(year: 2026, month: 5, day: 27, hour: 12)])
        // Future date
        let future = DictRow(["Z_PK": 4, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0,
                              "list_name": "L", "ZDUEDATE": appleSeconds(year: 2026, month: 6, day: 15)])

        let data = remindersToTableData([today, tomorrow, overdue, future], ansi: plain, now: now)
        #expect(data[0].due == "Today")
        #expect(data[1].due == "Tomorrow")
        #expect(data[2].due == "Overdue 2d")
        #expect(data[3].due == "2026-06-15")
    }

    @Test func remindersToTableDataTodayWithTime() {
        let now = pinnedNow
        let row = DictRow(["Z_PK": 1, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0,
                           "list_name": "L", "ZDUEDATE": appleSeconds(year: 2026, month: 5, day: 29, hour: 14, minute: 30)])
        let data = remindersToTableData([row], ansi: plain, now: now)
        #expect(data[0].due == "Today 14:30")
    }

    @Test func remindersToTableDataNoDue() {
        let row = DictRow(["Z_PK": 1, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0, "list_name": "L"])
        let data = remindersToTableData([row], ansi: plain, now: pinnedNow)
        #expect(data[0].due == "")
    }

    @Test func remindersToTableDataTitleMarkers() {
        let row = DictRow(["Z_PK": 42, "ZTITLE": "Title", "list_name": "Work",
                           "ZISURGENTSTATEENABLEDFORCURRENTUSER": 1, "ZFLAGGED": 1,
                           "ZCOMPLETED": 0, "ZPRIORITY": 0])
        let data = remindersToTableData([row], ansi: plain, now: pinnedNow)
        // urgent ⏰ before flagged ⚑ (uncolored markers).
        #expect(data[0].title == "⏰ ⚑ Title")
    }

    @Test func remindersToTableDataUntitledAndId() {
        let row = DictRow(["Z_PK": 7, "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0])
        let data = remindersToTableData([row], ansi: plain, now: pinnedNow)
        #expect(data[0].title == "(untitled)")
        #expect(data[0].id == "#7")
        #expect(data[0].list == "L")
    }

    @Test func remindersToTableDataPriority() {
        let row = DictRow(["Z_PK": 1, "ZTITLE": "t", "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 1])
        let data = remindersToTableData([row], ansi: plain, now: pinnedNow)
        #expect(data[0].pri == "!!!")
    }

    @Test func remindersToTableDataRepeat() {
        // recurrence_frequency 1 == weekly (0 daily, 2 monthly, 3 yearly).
        let row = DictRow(["Z_PK": 1, "ZTITLE": "t", "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0,
                           "ZPRIORITY": 0, "recurrence_frequency": 1, "recurrence_interval": 1])
        let data = remindersToTableData([row], ansi: plain, now: pinnedNow)
        #expect(data[0].repeatText == "weekly")
    }

    @Test func endToEndUncoloredTable() {
        let row = DictRow(["Z_PK": 1, "ZTITLE": "Buy milk", "list_name": "Groceries",
                           "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0,
                           "ZDUEDATE": appleSeconds(year: 2026, month: 5, day: 29)])
        let data = remindersToTableData([row], ansi: plain, now: pinnedNow)
        let expected = """
        ┌────┬──────────┬───────────┬───────┬─────┐
        │ ID │ Title    │ List      │ Due   │ Pri │
        ├────┼──────────┼───────────┼───────┼─────┤
        │ #1 │ Buy milk │ Groceries │ Today │     │
        └────┴──────────┴───────────┴───────┴─────┘
        """
        #expect(fmtTable(data, maxWidth: 80) == expected)
    }
}
