import Testing
import Foundation
@testable import RemindersControl

@Suite struct OrderedJSONTests {
    @Test func preservesObjectKeyOrder() {
        let v = OrderedJSON.parse(Data(#"{"b":1,"a":2,"c":[3,4]}"#.utf8))!
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"b": 1, "a": 2, "c": [3, 4]}"#)
    }
    @Test func parsesNestedAndLiterals() {
        let v = OrderedJSON.parse(Data(#"{"x":{"y":true,"z":null},"w":"hi"}"#.utf8))!
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"x": {"y": true, "z": null}, "w": "hi"}"#)
    }
}

@Suite struct RecurrenceTests {
    @Test func weeklyMonWed() {
        let row = DictRow([
            "recurrence_frequency": 1, "recurrence_interval": 1,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":4}]"#,
        ])
        let rec = recurrenceFromRow(row, ts: { AppleEpoch.ts($0) })!
        let s = JSONValue.object(rec).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"frequency": "weekly", "interval": 1, "daysOfWeekDetailed": [{"weekNumber": 0, "dayOfTheWeek": 2}, {"weekNumber": 0, "dayOfTheWeek": 4}], "daysOfWeek": [2, 4]}"#)
    }
    @Test func intervalZeroBecomesOne() {
        let row = DictRow(["recurrence_frequency": 2, "recurrence_interval": 0])
        let rec = recurrenceFromRow(row, ts: { AppleEpoch.ts($0) })!
        #expect(JSONValue.object(rec).serialized(indent: nil, ensureAscii: true) == #"{"frequency": "monthly", "interval": 1}"#)
    }
    @Test func noRecurrenceWhenFrequencyMissing() {
        #expect(recurrenceFromRow(DictRow([:]), ts: { AppleEpoch.ts($0) }) == nil)
    }
    @Test func earlyReminderBeforeLabel() {
        let row = DictRow(["ZDUEDATEDELTAALERTSDATA":
            #"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":0,"dueDateDeltaCount":-15,"identifier":"DELTA-1"}]}"#])
        let alerts = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        #expect(alerts.count == 1)
        let s = JSONValue.object(alerts[0]).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"unit": "minutes", "unitCode": 0, "count": -15, "value": 15, "direction": "before", "label": "15 minutes before", "identifier": "DELTA-1"}"#)
    }
    @Test func earlyReminderAfterWhenPositive() {
        let row = DictRow(["ZDUEDATEDELTAALERTSDATA": #"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":2,"dueDateDeltaCount":1}]}"#])
        let alerts = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        let s = JSONValue.object(alerts[0]).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"unit": "day", "unitCode": 2, "count": 1, "value": 1, "direction": "after", "label": "1 day after"}"#)
    }
}
