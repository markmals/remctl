import Foundation

public enum AppleEpoch {
    /// Seconds between Unix epoch (1970-01-01) and Apple/CoreData reference date (2001-01-01 UTC).
    public static let offset: Double = 978_307_200

    /// `ts(v)` — nil for falsey (0/nil); else Apple seconds -> local-naive ISO string.
    public static func ts(_ v: Double?, calendar: Calendar = .current) -> String? {
        guard let v, v != 0 else { return nil }
        return tsForce(v, calendar: calendar)
    }

    /// Like ts but does not short-circuit 0.
    public static func tsForce(_ v: Double, calendar: Calendar = .current) -> String {
        isoLocalNoTZ(Date(timeIntervalSince1970: v + offset), calendar: calendar)
    }

    /// `to_ts(dt)` — Date -> Apple seconds.
    public static func toTs(_ d: Date) -> Double { d.timeIntervalSince1970 - offset }

    /// Mirror Python datetime.isoformat() for a naive LOCAL datetime:
    /// "YYYY-MM-DDTHH:MM:SS" with ".ffffff" appended only when microseconds != 0.
    public static func isoLocalNoTZ(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                       c.year ?? 0, c.month ?? 0, c.day ?? 0,
                       c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let micros = Int((c.nanosecond ?? 0) / 1000)
        if micros != 0 { s += String(format: ".%06d", micros) }
        return s
    }
}
