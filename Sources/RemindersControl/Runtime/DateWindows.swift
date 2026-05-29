import Foundation

public enum DateWindows {
    public static func startOfDay(_ now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }
    public static func dueTodayWindow(_ now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let sod = startOfDay(now, calendar: calendar)
        return (sod, calendar.date(byAdding: .day, value: 1, to: sod)!)
    }
    public static func upcomingWindow(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let sod = startOfDay(now, calendar: calendar)
        return (sod, calendar.date(byAdding: .day, value: days + 1, to: sod)!)
    }
}
