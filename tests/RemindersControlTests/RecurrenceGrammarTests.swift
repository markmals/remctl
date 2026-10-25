import Testing
import Foundation
import EventKit
@testable import RemindersControl

/// The `xN` interval token and monthly Nth-weekday tokens (upstream c84fbca), from the CLI
/// string through the EventKit rule and back to the human summary.
@Suite struct RecurrenceGrammarTests {

    private func parse(_ spec: String) -> RecurrenceWrite? { WriteParsing.parseRecurrenceSpec(spec) }

    @Test func intervalTokenFollowsAnyFrequency() {
        #expect(parse("yearly x2") == RecurrenceWrite(frequency: "yearly", interval: 2))
        #expect(parse("weekly x2 thu") == RecurrenceWrite(frequency: "weekly", interval: 2, daysOfWeek: [5]))
        #expect(parse("monthly x6") == RecurrenceWrite(frequency: "monthly", interval: 6))
        #expect(parse("monthly x2 4th-fri")
            == RecurrenceWrite(frequency: "monthly", interval: 2, daysOfWeek: [6], weekNumbers: [4]))
        #expect(parse("daily x999") == RecurrenceWrite(frequency: "daily", interval: 999))
        #expect(parse("monthly x3 15") == RecurrenceWrite(frequency: "monthly", interval: 3, daysOfMonth: [15]))
        #expect(parse("Daily X2") == RecurrenceWrite(frequency: "daily", interval: 2))
    }

    @Test(arguments: ["yearly x0", "yearly x", "yearly x1000", "yearly x²", "yearly x-1",
                      "daily x2 extra", "daily x2 mon", "weekly x2 thu extra", "weekly thu x2",
                      "daily x2 x3", "yearly x" + String(repeating: "9", count: 5000)])
    func intervalTokenRejects(_ spec: String) {
        #expect(parse(spec) == nil)
    }

    @Test func nthWeekdayTokens() {
        #expect(parse("monthly 4th-fri")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [6], weekNumbers: [4]))
        #expect(parse("monthly 1st-mon,3rd-mon")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [2, 2], weekNumbers: [1, 3]))
        #expect(parse("monthly -1-fri")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [6], weekNumbers: [-1]))
        #expect(parse("monthly last-fri") == parse("monthly -1-fri"))
        #expect(parse("monthly last-sun")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [1], weekNumbers: [-1]))
        #expect(parse("monthly 2nd-tue,-2-thu")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [3, 5], weekNumbers: [2, -2]))
        #expect(parse("monthly 5th-sat,-5-sun")
            == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [7, 1], weekNumbers: [5, -5]))
    }

    @Test(arguments: ["monthly 6th-fri", "monthly 0th-fri", "monthly -6-fri", "monthly -0-fri",
                      "monthly 4st-fri", "monthly 1th-fri", "monthly 2rd-fri", "monthly 4th-funday",
                      "monthly 4th-fri,15", "monthly 15,4th-fri", "monthly last-funday", "monthly 4thfri",
                      "monthly --1-fri", "monthly 4th-", "weekly 4th-fri", "yearly 4th-fri", "daily last-fri",
                      "monthly ²", "monthly " + String(repeating: "9", count: 5000)])
    func nthWeekdayAndDayOfMonthReject(_ spec: String) {
        #expect(parse(spec) == nil)
    }

    @Test func nthWeekdaySpecBuildsPinnedEventKitRule() throws {
        let spec = try #require(parse("monthly x2 last-fri"))
        let rule = try #require(EventKitWriter().buildRecurrenceRule(spec))
        #expect(rule.frequency == .monthly)
        #expect(rule.interval == 2)
        #expect(rule.daysOfTheWeek?.map { $0.dayOfTheWeek } == [.friday])
        #expect(rule.daysOfTheWeek?.map { $0.weekNumber } == [-1])
    }

    @Test func eventKitReadSurfacesWeekNumbersOnlyWhenPinned() {
        let pinned = EKRecurrenceRule(
            recurrenceWith: .monthly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(dayOfTheWeek: .tuesday, weekNumber: 4)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil)
        let pinnedJSON = EventKitReader.recurrenceJSON(pinned)
        #expect(pinnedJSON.first(where: { $0.0 == "weekNumbers" })?.1 == .array([.int(4)]))
        #expect(recurrenceSummary(pinnedJSON) == "monthly 4th Tue")

        let plain = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil)
        #expect(!EventKitReader.recurrenceJSON(plain).contains(where: { $0.0 == "weekNumbers" }))
    }

    // MARK: - Human summary

    private func summary(_ pairs: [(String, JSONValue)]) -> String { recurrenceSummary(pairs) }
    private func ints(_ values: [Int]) -> JSONValue { .array(values.map { .int($0) }) }

    @Test func summaryRendersWeekPinnedDays() {
        let monthlyFri: [(String, JSONValue)] = [("frequency", .string("monthly")), ("interval", .int(1)), ("daysOfWeek", ints([6]))]
        #expect(summary(monthlyFri + [("weekNumbers", ints([4]))]) == "monthly 4th Fri")
        #expect(summary(monthlyFri + [("weekNumbers", ints([-1]))]) == "monthly last Fri")
        #expect(summary(monthlyFri + [("weekNumbers", ints([-2]))]) == "monthly 2nd-last Fri")
        #expect(summary([("frequency", .string("monthly")), ("interval", .int(2)),
                         ("daysOfWeek", ints([3])), ("weekNumbers", ints([4]))]) == "every 2 months 4th Tue")
        // A short weekNumbers list leaves the remaining days unpinned.
        #expect(summary([("frequency", .string("weekly")), ("interval", .int(1)), ("daysOfWeek", ints([2, 4]))])
            == "weekly Mon, Wed")
    }

    @Test func summaryReadsStoredDetailedBlob() {
        let stored = recurrenceFromRow(DictRow([
            "recurrence_frequency": 2, "recurrence_interval": 2,
            "recurrence_days_of_week": #"[{"weekNumber":4,"dayOfTheWeek":3}]"#,
        ]), ts: { AppleEpoch.ts($0) })!
        #expect(summary(stored) == "every 2 months 4th Tue")

        let anyWeek = recurrenceFromRow(DictRow([
            "recurrence_frequency": 1, "recurrence_interval": 1,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":4}]"#,
        ]), ts: { AppleEpoch.ts($0) })!
        #expect(summary(anyWeek) == "weekly Mon, Wed")
    }

    @Test func summaryRendersOccurrenceCountsAsTimes() {
        #expect(summary([("frequency", .string("daily")), ("interval", .int(1)), ("count", .int(5))]) == "daily, 5 times")
        #expect(summary([("frequency", .string("daily")), ("interval", .int(1)), ("count", .int(1))]) == "daily, 1 time")
    }
}
