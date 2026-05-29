import Testing
import Foundation
@testable import RemindersControl

@Suite struct AppleEpochTests {
    private func romeCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private func utcCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func tsConvertsAppleEpochToLocalNaiveISO() {
        #expect(AppleEpoch.ts(801216000, calendar: romeCal()) == "2026-05-23T10:00:00")
        #expect(AppleEpoch.ts(801215100, calendar: romeCal()) == "2026-05-23T09:45:00")
    }
    @Test func tsReturnsNilForFalsey() {
        #expect(AppleEpoch.ts(0) == nil)
        #expect(AppleEpoch.ts(nil) == nil)
    }
    @Test func toTsIsInverseOffset() {
        let unix = 801216000.0 + 978307200.0
        #expect(AppleEpoch.toTs(Date(timeIntervalSince1970: unix)) == 801216000)
    }
    @Test func zeroAppleSecondsIsReferenceDateUTC() {
        // 0 apple-seconds == 2001-01-01T00:00:00 in UTC; tsForce does not short-circuit 0.
        #expect(AppleEpoch.tsForce(0, calendar: utcCal()) == "2001-01-01T00:00:00")
    }
    @Test func fractionalSecondsAppendedWhenNonzero() {
        // 0.5 apple-seconds -> 500000 microseconds appended
        #expect(AppleEpoch.tsForce(0.5, calendar: utcCal()) == "2001-01-01T00:00:00.500000")
    }
}

@Suite struct DateWindowTests {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c
    }
    private func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal().date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
    }
    @Test func startOfDayTruncates() {
        #expect(DateWindows.startOfDay(d(2026,4,18,14,30), calendar: cal()) == d(2026,4,18,0,0))
    }
    @Test func dueTodayWindowIsSodToSodPlusOne() {
        let (a,b) = DateWindows.dueTodayWindow(d(2026,4,18,14,30), calendar: cal())
        #expect(a == d(2026,4,18)); #expect(b == d(2026,4,19))
    }
    @Test func upcomingWindowAddsDaysPlusOne() {
        let (a,b) = DateWindows.upcomingWindow(days: 7, now: d(2026,4,18,14,30), calendar: cal())
        #expect(a == d(2026,4,18)); #expect(b == d(2026,4,26)) // sod + 8 days
    }
    @Test func upcomingDefaultDaysIsSeven() {
        let (a,b) = DateWindows.upcomingWindow(now: d(2026,4,18,14,30), calendar: cal())
        #expect(a == d(2026,4,18)); #expect(b == d(2026,4,26))
    }
}
