import Testing
import Foundation
import EventKit
@testable import RemindersControl

/// Exported recurrence objects (`export`, `info --json`) must survive a round trip back through
/// the write path: `recurrenceFromRow` → JSON → `WriteParsing` → `EKRecurrenceRule`.
@Suite struct RecurrenceObjectTests {

    /// Serialize a fixture row's recurrence exactly as `export` writes it.
    private func exported(_ row: [String: Any?]) -> String {
        let rec = recurrenceFromRow(DictRow(row), ts: { AppleEpoch.ts($0) })!
        return JSONValue.object(rec).serialized(indent: nil, ensureAscii: true)
    }

    private func rule(_ spec: RecurrenceWrite) -> EKRecurrenceRule? {
        EventKitWriter().buildRecurrenceRule(spec)
    }

    @Test func weeklyExportRoundTrips() {
        let json = exported([
            "recurrence_frequency": 1, "recurrence_interval": 2,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":4}]"#,
        ])
        let spec = WriteParsing.parseRecurrenceSpec(json)
        #expect(spec == RecurrenceWrite(frequency: "weekly", interval: 2, daysOfWeek: [2, 4], weekNumbers: [0, 0]))

        let built = rule(spec!)
        #expect(built?.frequency == .weekly)
        #expect(built?.interval == 2)
        #expect(built?.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } == [2, 4])
        #expect(built?.daysOfTheWeek?.map { $0.weekNumber } == [0, 0])
    }

    @Test func monthlyNthWeekdayExportRoundTrips() {
        let json = exported([
            "recurrence_frequency": 2, "recurrence_interval": 1,
            "recurrence_days_of_week": #"[{"weekNumber":4,"dayOfTheWeek":6}]"#,
        ])
        let spec = WriteParsing.parseRecurrenceSpec(json)
        #expect(spec == RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [6], weekNumbers: [4]))
        let built = rule(spec!)
        #expect(built?.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } == [6])
        #expect(built?.daysOfTheWeek?.map { $0.weekNumber } == [4])
    }

    @Test func yearlySetFieldsAndCountRoundTrip() {
        let json = exported([
            "recurrence_frequency": 3, "recurrence_interval": 1,
            "recurrence_months_of_year": "[3, 9]",
            "recurrence_weeks_of_year": "[-1]",
            "recurrence_days_of_year": "[100]",
            "recurrence_set_positions": "[-1]",
            "recurrence_count": 5,
        ])
        let spec = WriteParsing.parseRecurrenceSpec(json)
        #expect(spec == RecurrenceWrite(frequency: "yearly", interval: 1, monthsOfYear: [3, 9],
                                        daysOfYear: [100], weeksOfYear: [-1], setPositions: [-1], count: 5))
        let built = rule(spec!)
        #expect(built?.monthsOfTheYear?.map { $0.intValue } == [3, 9])
        #expect(built?.weeksOfTheYear?.map { $0.intValue } == [-1])
        #expect(built?.daysOfTheYear?.map { $0.intValue } == [100])
        #expect(built?.setPositions?.map { $0.intValue } == [-1])
        #expect(built?.recurrenceEnd?.occurrenceCount == 5)
    }

    @Test func monthlyDaysOfMonthAndEndDateRoundTrip() {
        // 2027-03-04T09:30:00 local, as an Apple-epoch timestamp.
        var comps = DateComponents()
        comps.year = 2027; comps.month = 3; comps.day = 4; comps.hour = 9; comps.minute = 30
        let endDate = Calendar.current.date(from: comps)!
        let json = exported([
            "recurrence_frequency": 2, "recurrence_interval": 1,
            "recurrence_days_of_month": "[1, 15]",
            "recurrence_end_date": AppleEpoch.toTs(endDate),
        ])
        let spec = WriteParsing.parseRecurrenceSpec(json)
        #expect(spec?.daysOfMonth == [1, 15])
        #expect(spec?.end == endDate)
        let built = rule(spec!)
        #expect(built?.daysOfTheMonth?.map { $0.intValue } == [1, 15])
        #expect(built?.recurrenceEnd?.endDate == endDate)
    }

    @Test func acceptsIsoEndDateSpellings() {
        for text in ["2028-09-26T09:00", "2028-09-26T09:00:00", "2028-09-26 09:00:00",
                     "2028-09-26T09:00:00.125", "2028-09-26T09:00:00.125+02:00",
                     "2028-09-26T09:00:00+01:30:20", "2028-09-26T09:00:00Z",
                     "2028-09-26T09:00:00-0700", "2028-09-26", "2028-W39-2"] {
            let spec = WriteParsing.parseRecurrence(.object([("frequency", .string("daily")),
                                                             ("endDate", .string(text))]))
            #expect(spec?.end != nil, "expected a parsed end date for \(text)")
        }
        // Zone-aware spellings resolve to the same instant.
        let utc = WriteParsing.parseRecurrence(.object([("frequency", .string("daily")),
                                                        ("endDate", .string("2028-09-26T09:00:00Z"))]))
        let offset = WriteParsing.parseRecurrence(.object([("frequency", .string("daily")),
                                                           ("endDate", .string("2028-09-26T11:00:00+02:00"))]))
        #expect(utc?.end == offset?.end)
    }

    @Test func rejectsMalformedEndDates() {
        for text in ["", "tomorrow", "2028-13-01T00:00:00", "2028-02-30", "2028-09-26T25:00:00",
                     "2028-09-26T09:00:00+99:99", "2028-W54-2"] {
            let spec = WriteParsing.parseRecurrence(.object([("frequency", .string("daily")),
                                                             ("endDate", .string(text))]))
            #expect(spec == nil, "expected rejection of end date \(text)")
        }
    }

    @Test func rejectsInvalidRecurrenceObjects() {
        let cases: [JSONValue] = [
            .object([]),                                                          // {}
            .array([]),                                                           // []
            .bool(false),
            .int(0),
            .string(""),
            .object([("frequency", .string("hourly"))]),                          // unknown frequency
            .object([("frequency", .string("daily")), ("nope", .int(1))]),        // unknown field
            .object([("frequency", .string("daily")), ("interval", .int(0))]),
            .object([("frequency", .string("daily")), ("interval", .double(2.5))]),
            .object([("frequency", .string("daily")), ("count", .bool(false))]),
            .object([("frequency", .string("daily")), ("count", .int(0))]),
            .object([("frequency", .string("weekly")), ("daysOfWeek", .array([]))]),
            .object([("frequency", .string("weekly")), ("daysOfWeek", .array([.int(8)]))]),
            .object([("frequency", .string("monthly")), ("daysOfMonth", .array([.int(0)]))]),
            .object([("frequency", .string("yearly")), ("monthsOfYear", .array([.int(13)]))]),
            // weekNumbers must be parallel to daysOfWeek and inside the frequency's bound.
            .object([("frequency", .string("monthly")), ("daysOfWeek", .array([.int(6)])),
                     ("weekNumbers", .array([.int(6)]))]),
            .object([("frequency", .string("monthly")), ("daysOfWeek", .array([.int(6)])),
                     ("weekNumbers", .array([.int(1), .int(2)]))]),
            .object([("frequency", .string("weekly")), ("daysOfWeek", .array([.int(6)])),
                     ("weekNumbers", .array([.int(2)]))]),
            // daysOfWeekDetailed must agree with any explicit arrays.
            .object([("frequency", .string("weekly")),
                     ("daysOfWeekDetailed", .array([.object([("dayOfTheWeek", .int(2))])])),
                     ("daysOfWeek", .array([.int(4)]))]),
            .object([("frequency", .string("weekly")), ("daysOfWeekDetailed", .array([]))]),
            .object([("frequency", .string("weekly")),
                     ("daysOfWeekDetailed", .array([.object([("weekNumber", .int(1))])]))]),
            // end and count are mutually exclusive.
            .object([("frequency", .string("daily")), ("count", .int(3)),
                     ("endDate", .string("2028-09-26T09:00:00"))]),
            // endDate and end must agree when both are present.
            .object([("frequency", .string("daily")), ("end", .string("2028-09-26T09:00:00")),
                     ("endDate", .string("2029-09-26T09:00:00"))]),
        ]
        for value in cases {
            #expect(WriteParsing.parseRecurrence(value) == nil, "expected rejection of \(value)")
        }
    }

    @Test func rejectsRecurrenceObjectTextThatIsNotAnObject() {
        #expect(WriteParsing.parseRecurrenceSpec("{not json") == nil)
        #expect(WriteParsing.parseRecurrenceSpec("{}") == nil)
    }

    @Test func stringGrammarStillWorksThroughTheObjectAwareParser() {
        #expect(WriteParsing.parseRecurrence(.string("weekly mon,wed"))
            == RecurrenceWrite(frequency: "weekly", interval: 1, daysOfWeek: [2, 4]))
        #expect(WriteParsing.parseRecurrence(.int(3)) == nil)
        #expect(WriteParsing.parseRecurrence(.null) == nil)
    }

    @Test func buildRejectsOutOfRangeWeekNumbersBeforeEventKit() {
        // EKRecurrenceDayOfWeek raises an uncatchable NSException on these, so the rule builder
        // must refuse them even if a caller skipped normalization.
        #expect(rule(RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [6], weekNumbers: [6])) == nil)
        #expect(rule(RecurrenceWrite(frequency: "yearly", interval: 1, daysOfWeek: [6], weekNumbers: [54])) == nil)
        #expect(rule(RecurrenceWrite(frequency: "weekly", interval: 1, daysOfWeek: [6], weekNumbers: [2])) == nil)
        #expect(rule(RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [6, 5], weekNumbers: [1])) == nil)
        // Valid pins still build.
        #expect(rule(RecurrenceWrite(frequency: "monthly", interval: 1, daysOfWeek: [6], weekNumbers: [-1])) != nil)
    }

    @Test func buildRejectsCountAndEndTogether() {
        let spec = RecurrenceWrite(frequency: "daily", interval: 1, count: 3, end: Date())
        #expect(rule(spec) == nil)
    }
}
