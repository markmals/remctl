import Testing
import Foundation
@testable import RemindersControl

@Suite struct ReminderFormatTests {
    let off = Ansi(enabled: false)
    private func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private func appleSecondsFor(_ date: Date) -> Double { AppleEpoch.toTs(date) }

    @Test func lineWithMarkersUncolored() {
        let row = DictRow(["Z_PK": 42, "ZTITLE": "Urgent flagged", "list_name": "Work",
            "ZCOMPLETED": 0, "ZFLAGGED": 1, "ZISURGENTSTATEENABLEDFORCURRENTUSER": 1, "ZPRIORITY": 0])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, indent: "  ") == "  [ ] #42 ⏰ ⚑ Urgent flagged")
    }
    @Test func priorityHighMarker() {
        let row = DictRow(["Z_PK": 1, "ZTITLE": "t", "ZPRIORITY": 1, "ZCOMPLETED": 0, "ZFLAGGED": 0])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off) == "[ ] #1 !!! t")
    }
    @Test func untitledFallback() {
        let row = DictRow(["Z_PK": 1, "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off) == "[ ] #1 (untitled)")
    }
    @Test func tagsAndSubtaskSuffix() {
        let row = DictRow(["Z_PK": 1, "ZTITLE": "t", "ZCOMPLETED": 0, "ZFLAGGED": 0, "ZPRIORITY": 0])
        #expect(fmt(row, tags: ["work","home"], subtaskCount: 2, ansi: off) == "[ ] #1 t #work #home [2 subtasks]")
        #expect(fmt(row, tags: [], subtaskCount: 1, ansi: off) == "[ ] #1 t [1 subtask]")
    }
    @Test func dueToday() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14,minute:0))!
        let dueDate = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:9,minute:30))!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,"ZDUEDATE": appleSecondsFor(dueDate)])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now) == "[ ] #1 t (today 09:30)")
    }
    @Test func dueOverdue() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14))!
        let due = cal.date(byAdding: .day, value: -2, to: now)!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,"ZDUEDATE": appleSecondsFor(due)])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now) == "[ ] #1 t (overdue 2d)")
    }
    @Test func dueFutureDate() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14))!
        let due = cal.date(from: DateComponents(year:2026,month:6,day:15,hour:9))!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,"ZDUEDATE": appleSecondsFor(due)])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now) == "[ ] #1 t (2026-06-15)")
    }
    @Test func recurrenceBadgeWeekly() {
        // recurrence_days_of_week JSON: Mon(2), Wed(4)
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,
            "recurrence_frequency":1,"recurrence_interval":1,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":4}]"#])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off) == "[ ] #1 t ↻ weekly Mon, Wed")
    }
    @Test func recurrenceSummaryEveryNWeeks() {
        let rec = recurrenceFromRow(DictRow(["recurrence_frequency":1,"recurrence_interval":2]), ts: { AppleEpoch.ts($0) })!
        #expect(recurrenceSummary(rec) == "every 2 weeks")
    }
    @Test func completedUncoloredHasPlainStrikethroughTitle() {
        // uncolored: dim(strikethrough(title)) == title; status [x]
        let row = DictRow(["Z_PK":1,"ZTITLE":"done","ZCOMPLETED":1,"ZFLAGGED":0,"ZPRIORITY":0])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off) == "[x] #1 done")
    }
    @Test func coloredMarkersWrapSGR() {
        let on = Ansi(enabled: true)
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":1,"ZISURGENTSTATEENABLEDFORCURRENTUSER":1,"ZPRIORITY":0])
        let line = fmt(row, tags: [], subtaskCount: 0, ansi: on)
        #expect(line.contains("\u{1B}[31m⏰\u{1B}[0m"))   // urgent red
        #expect(line.contains("\u{1B}[33m⚑\u{1B}[0m"))   // flagged yellow
    }
    @Test func verboseAppendsDetailLines() {
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","list_name":"Work","ZNOTES":"hi","ZICSURL":"https://x",
            "ZCOMPLETED":0,"ZFLAGGED":1,"ZISURGENTSTATEENABLEDFORCURRENTUSER":1,"ZPRIORITY":0])
        let out = fmt(row, tags: [], subtaskCount: 0, ansi: off, verbose: true)
        #expect(out.contains("\n    List: Work"))
        #expect(out.contains("\n    Notes: hi"))
        #expect(out.contains("\n    URL: https://x"))
        #expect(out.contains("\n    Flagged: Yes"))
        #expect(out.contains("\n    Urgent: Yes"))
    }

    // ── all-day reminders (port of Fix all-day reminder bucketing) ────────────
    @Test func allDayDueTodaySuppressesTime() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14))!
        let due = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:9,minute:30))!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,
            "ZALLDAY":1,"ZDUEDATE": appleSecondsFor(due)])
        // 📅 marker, and the time-of-day is suppressed: "(today)" not "(today 09:30)".
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now) == "[ ] #1 📅 t (today)")
    }
    @Test func allDayLabelsByDisplayDateNotSyntheticDue() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14))!
        // Synthetic ZDUEDATE on the previous day (UTC-midnight artifact); display date = today.
        let synthDue = cal.date(from: DateComponents(year:2026,month:5,day:28,hour:20))!
        let display = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:0))!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,
            "ZALLDAY":1,"ZDUEDATE": appleSecondsFor(synthDue),"ZDISPLAYDATEDATE": appleSecondsFor(display)])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now) == "[ ] #1 📅 t (today)")
    }
    @Test func verboseIncludesAllDayLine() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14))!
        let due = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:9))!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,
            "ZALLDAY":1,"ZDUEDATE": appleSecondsFor(due)])
        let out = fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now, verbose: true)
        #expect(out.contains("\n    All-day: Yes"))
    }
    @Test func nonAllDayStillShowsTime() {
        let cal = cal()
        let now = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:14))!
        let due = cal.date(from: DateComponents(year:2026,month:5,day:29,hour:9,minute:30))!
        let row = DictRow(["Z_PK":1,"ZTITLE":"t","ZCOMPLETED":0,"ZFLAGGED":0,"ZPRIORITY":0,
            "ZALLDAY":0,"ZDUEDATE": appleSecondsFor(due)])
        #expect(fmt(row, tags: [], subtaskCount: 0, ansi: off, now: now) == "[ ] #1 t (today 09:30)")
    }
}
