import Testing
import Foundation
@testable import RemindersControl

@Suite struct WriteParsingTests {
    private func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private func now() -> Date { cal().date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 9, minute: 0))! } // a Wednesday

    @Test func dueTodayTomorrowTonightFridayWithTimes() {
        let c = cal(), n = now()
        let today = WriteParsing.parseDue("today at 3pm", now: n, calendar: c)!
        #expect(c.component(.hour, from: today) == 15 && c.component(.minute, from: today) == 0)
        let tomorrow = WriteParsing.parseDue("tomorrow 15:30", now: n, calendar: c)!
        #expect(c.component(.hour, from: tomorrow) == 15 && c.component(.minute, from: tomorrow) == 30)
        #expect(c.dateComponents([.day], from: today, to: tomorrow).day == 1)
        let tonight = WriteParsing.parseDue("tonight at 11", now: n, calendar: c)!
        #expect(c.component(.hour, from: tonight) == 23 && c.component(.minute, from: tonight) == 0)
        let friday = WriteParsing.parseDue("Friday at 15:00", now: n, calendar: c)!
        #expect(c.component(.hour, from: friday) == 15 && c.component(.minute, from: friday) == 0)
    }
    @Test func dueRejectsInvalidClock() {
        #expect(WriteParsing.parseDue("today at 25:00", now: now(), calendar: cal()) == nil)
    }
    @Test func recurrenceWeeklyDays() {
        #expect(WriteParsing.parseRecurrenceSpec("weekly mon,wed") == RecurrenceWrite(frequency: "weekly", interval: 1, daysOfWeek: [2, 4]))
    }
    @Test func recurrenceRejectsInvalid() {
        #expect(WriteParsing.parseRecurrenceSpec("fortnightly") == nil)
        #expect(WriteParsing.parseRecurrenceSpec("weekly funday") == nil)
        #expect(WriteParsing.parseRecurrenceSpec("monthly 0,32") == nil)
    }
    @Test func alarmRelativeAndAbsolute() {
        #expect(WriteParsing.parseAlarmSpec("15m") == .relativeOffset(-900))
        #expect(WriteParsing.parseAlarmSpec("2h") == .relativeOffset(-7200))
        let c = cal()
        let abs = WriteParsing.parseAlarmSpec("2026-04-15 14:00", calendar: c)
        if case let .absolute(d)? = abs {
            #expect(c.component(.hour, from: d) == 14 && c.component(.year, from: d) == 2026)
        } else { Issue.record("expected .absolute") }
    }
    @Test func alarmClearKeywordOnlyWhenAllowed() {
        #expect(WriteParsing.parseAlarmSpec("clear") == nil)              // not allowed by default (add)
        #expect(WriteParsing.parseAlarmSpec("clear", allowClear: true) == .clear)  // edit
    }
    @Test func priorityMaps() {
        #expect(WriteParsing.parsePriority("high", allowAliases: true) == 1)
        #expect(WriteParsing.parsePriority("h", allowAliases: true) == 1)
        #expect(WriteParsing.parsePriority("med", allowAliases: true) == 5)
        #expect(WriteParsing.parsePriority("none", allowAliases: true) == 0)
        #expect(WriteParsing.parsePriority("h", allowAliases: false) == nil)   // edit has no aliases
        #expect(WriteParsing.parsePriority("medium", allowAliases: false) == 5)
        #expect(WriteParsing.parsePriority("bogus", allowAliases: true) == nil)
    }

    // ── Additional parity coverage (beyond the seed oracle) ───────────────────

    @Test func dueExactShortcuts() {
        let c = cal(), n = now()
        let today = WriteParsing.parseDue("today", now: n, calendar: c)!
        #expect(c.dateComponents([.year, .month, .day, .hour, .minute], from: today)
            == DateComponents(year: 2026, month: 4, day: 15, hour: 0, minute: 0))
        let tomorrow = WriteParsing.parseDue("tomorrow", now: n, calendar: c)!
        #expect(c.component(.day, from: tomorrow) == 16 && c.component(.hour, from: tomorrow) == 0)
        let eod = WriteParsing.parseDue("eod", now: n, calendar: c)!
        #expect(c.component(.hour, from: eod) == 17 && c.component(.day, from: eod) == 15)
        // Wed 2026-04-15: next Friday is 2026-04-17.
        let eow = WriteParsing.parseDue("eow", now: n, calendar: c)!
        #expect(c.component(.day, from: eow) == 17 && c.component(.hour, from: eow) == 0)
    }

    @Test func dueRelativeOffsets() {
        let c = cal(), n = now()
        let d3 = WriteParsing.parseDue("+3d", now: n, calendar: c)!
        #expect(c.component(.day, from: d3) == 18 && c.component(.hour, from: d3) == 0)
        let w1 = WriteParsing.parseDue("+1w", now: n, calendar: c)!
        #expect(c.component(.day, from: w1) == 22)
        // +2h is relative to now (09:00) -> 11:00 same day.
        let h2 = WriteParsing.parseDue("+2h", now: n, calendar: c)!
        #expect(c.component(.hour, from: h2) == 11 && c.component(.minute, from: h2) == 0)
        // Nm = N*30 days from midnight today.
        let midnight = c.startOfDay(for: n)
        let m1 = WriteParsing.parseDue("+1m", now: n, calendar: c)!
        #expect(c.dateComponents([.day], from: midnight, to: m1).day == 30)
    }

    @Test func dueInNUnits() {
        let c = cal(), n = now()
        #expect(c.component(.day, from: WriteParsing.parseDue("in 3 days", now: n, calendar: c)!) == 18)
        #expect(c.component(.day, from: WriteParsing.parseDue("in 2 weeks", now: n, calendar: c)!) == 29)
        let h = WriteParsing.parseDue("in 5 hours", now: n, calendar: c)!
        #expect(c.component(.hour, from: h) == 14)
    }

    @Test func dueNextWeekdayForcesPlus7() {
        let c = cal(), n = now() // Wednesday
        // "next wednesday" on a Wednesday forces +7 -> 2026-04-22.
        let nextWed = WriteParsing.parseDue("next wednesday", now: n, calendar: c)!
        #expect(c.component(.day, from: nextWed) == 22)
        // bare "wednesday" with no time -> today (days_ahead 0).
        let thisWed = WriteParsing.parseDue("wednesday", now: n, calendar: c)!
        #expect(c.component(.day, from: thisWed) == 15)
    }

    @Test func duePastTimeTodayRollsForWeekday() {
        let c = cal(), n = now() // Wed 09:00
        // "wednesday at 8" (08:00) is already past -> rolls +7 to 2026-04-22.
        let rolled = WriteParsing.parseDue("wednesday at 8am", now: n, calendar: c)!
        #expect(c.component(.day, from: rolled) == 22 && c.component(.hour, from: rolled) == 8)
    }

    @Test func dueISOForms() {
        let c = cal()
        let n = now()
        let dateOnly = WriteParsing.parseDue("2026-04-15", now: n, calendar: c)!
        #expect(c.dateComponents([.year, .month, .day, .hour, .minute], from: dateOnly)
            == DateComponents(year: 2026, month: 4, day: 15, hour: 0, minute: 0))
        let space = WriteParsing.parseDue("2026-04-15 14:00", now: n, calendar: c)!
        #expect(c.component(.hour, from: space) == 14)
        let t = WriteParsing.parseDue("2026-04-15T14:30", now: n, calendar: c)!
        #expect(c.component(.hour, from: t) == 14 && c.component(.minute, from: t) == 30)
        let tSec = WriteParsing.parseDue("2026-04-15T14:30:45", now: n, calendar: c)!
        #expect(c.component(.second, from: tSec) == 45)
    }

    @Test func dueTonightRollsToNextDayWhenPast() {
        let c = cal()
        // now = 22:00; "tonight at 9" (bare 9 -> 21:00) is past -> rolls to tomorrow 21:00.
        let n = c.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 22, minute: 0))!
        let t = WriteParsing.parseDue("tonight at 9", now: n, calendar: c)!
        #expect(c.component(.hour, from: t) == 21 && c.component(.day, from: t) == 16)
    }

    @Test func dueEmptyAndGarbage() {
        let c = cal(), n = now()
        #expect(WriteParsing.parseDue("", now: n, calendar: c) == nil)
        #expect(WriteParsing.parseDue("   ", now: n, calendar: c) == nil)
    }

    @Test func recurrenceDailyWeeklyMonthlyYearly() {
        #expect(WriteParsing.parseRecurrenceSpec("daily") == RecurrenceWrite(frequency: "daily", interval: 1))
        #expect(WriteParsing.parseRecurrenceSpec("yearly") == RecurrenceWrite(frequency: "yearly", interval: 1))
        #expect(WriteParsing.parseRecurrenceSpec("monthly 1,15")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfMonth: [1, 15]))
        // Bare weekly/monthly (no days) is valid.
        #expect(WriteParsing.parseRecurrenceSpec("weekly") == RecurrenceWrite(frequency: "weekly", interval: 1))
        #expect(WriteParsing.parseRecurrenceSpec("monthly") == RecurrenceWrite(frequency: "monthly", interval: 1))
    }

    @Test func recurrenceRejectsExtraTokensAndEmpty() {
        #expect(WriteParsing.parseRecurrenceSpec("") == nil)
        #expect(WriteParsing.parseRecurrenceSpec("daily mon") == nil)           // daily takes no args
        #expect(WriteParsing.parseRecurrenceSpec("weekly mon wed") == nil)      // must be one comma token
        #expect(WriteParsing.parseRecurrenceSpec("monthly 1 15") == nil)
    }

    @Test func alarmDayAndMinAliases() {
        #expect(WriteParsing.parseAlarmSpec("1d") == .relativeOffset(-86400))
        #expect(WriteParsing.parseAlarmSpec("30min") == .relativeOffset(-1800))
        #expect(WriteParsing.parseAlarmSpec("3hr") == .relativeOffset(-10800))
    }

    @Test func dueParityWithPythonFixedWednesday() {
        // Cross-checked against Python parse_due with now = 2026-04-15 09:00 (Wed).
        let c = cal(), n = now()
        func ymdhm(_ s: String) -> DateComponents? {
            guard let d = WriteParsing.parseDue(s, now: n, calendar: c) else { return nil }
            return c.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        }
        #expect(ymdhm("this friday") == DateComponents(year: 2026, month: 4, day: 17, hour: 0, minute: 0))
        #expect(ymdhm("sun") == DateComponents(year: 2026, month: 4, day: 19, hour: 0, minute: 0))
        #expect(ymdhm("mon at 9") == DateComponents(year: 2026, month: 4, day: 20, hour: 9, minute: 0))
        #expect(ymdhm("this monday at 7am") == DateComponents(year: 2026, month: 4, day: 20, hour: 7, minute: 0))
        #expect(ymdhm("today at 12am") == DateComponents(year: 2026, month: 4, day: 15, hour: 0, minute: 0))
        #expect(ymdhm("tomorrow at 12pm") == DateComponents(year: 2026, month: 4, day: 16, hour: 12, minute: 0))
    }

    @Test func dataDetectorFallbackHandlesPhrasesGrammarMisses() {
        // "12:30am" misses the explicit grammar (no space before ":30am" so the
        // weekday regex fails; ISO fails). The NSDataDetector fallback then parses
        // it as a bare clock time -> 00:30. This is the Swift analogue of Python's
        // OPTIONAL parsedatetime branch: with parsedatetime installed Python parses
        // this too; only the stripped test env (where _cal is None) returns nil.
        let c = cal(), n = now()
        let d = WriteParsing.parseDue("12:30am", now: n, calendar: c)
        #expect(d != nil)
        if let d { #expect(c.component(.minute, from: d) == 30) }
        // But a string the explicit grammar handled-and-rejected stays nil: the
        // detector is required to consume the WHOLE input, so an incidental time
        // substring inside "today at 25:00" is not picked up.
        #expect(WriteParsing.parseDue("today at 25:00", now: n, calendar: c) == nil)
    }

    @Test func clockTimeBoundaries() {
        #expect(WriteParsing.parseClockTime("12am").map { [$0.0, $0.1] } == [0, 0])
        #expect(WriteParsing.parseClockTime("12pm").map { [$0.0, $0.1] } == [12, 0])
        #expect(WriteParsing.parseClockTime("0").map { [$0.0, $0.1] } == [0, 0])
        #expect(WriteParsing.parseClockTime("23").map { [$0.0, $0.1] } == [23, 0])
        #expect(WriteParsing.parseClockTime("3 pm").map { [$0.0, $0.1] } == [15, 0])
        #expect(WriteParsing.parseClockTime("24") == nil)
        #expect(WriteParsing.parseClockTime("11:60") == nil)
        #expect(WriteParsing.parseClockTime("13pm") == nil) // am/pm hour must be 1-12
    }

    @Test func alarmRejectsGarbage() {
        #expect(WriteParsing.parseAlarmSpec("eventually") == nil)
        #expect(WriteParsing.parseAlarmSpec("") == nil)
        #expect(WriteParsing.parseAlarmSpec("none") == nil)               // clear not allowed by default
        #expect(WriteParsing.parseAlarmSpec("off", allowClear: true) == .clear)
        #expect(WriteParsing.parseAlarmSpec("remove", allowClear: true) == .clear)
        #expect(WriteParsing.parseAlarmSpec("delete", allowClear: true) == .clear)
    }
}
