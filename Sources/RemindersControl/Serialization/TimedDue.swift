import Foundation

/// Port of `timed_due_raw` (upstream 454d2c9, refined in 8f84a80). A timed reminder's due
/// date as a real instant, in Apple-epoch seconds.
///
/// Reminders stores a timed due date either as an instant, with `ZTIMEZONE` set, or as
/// floating wall-clock time encoded as if it were UTC, as GoodTask and older versions of
/// Reminders do: a 5 PM reminder is stored as 17:00Z. A row is floating when it has no time
/// zone, or when its display date is exactly the wall-clock reading. The match has to be
/// exact, because the display date can also be an alarm near the due time. When a zoned
/// row's display date matches that conversion, an absolute alarm is evidence that the
/// display date belongs to the alarm instead. All-day rows and instants come back unchanged.
///
/// `hasAbsoluteAlarm` resolves that last case and is only called for an ambiguous row, so
/// ordinary rows do no extra work. A row selected without `ZTIMEZONE` skips the no-time-zone
/// shortcut entirely: the absent column would otherwise read like a missing time zone.
public func timedDueRaw(_ row: ReminderRow, calendar: Calendar = .current,
                        hasAbsoluteAlarm: (() -> Bool)? = nil) -> Double? {
    let raw = row.double("ZDUEDATE")
    guard let raw, !itemIsAllDay(row) else { return raw }
    let floating = wallClockReading(raw, calendar: calendar)
    let hasTimeZoneColumn = row.has("ZTIMEZONE")
    if hasTimeZoneColumn, (row.string("ZTIMEZONE") ?? "").isEmpty { return floating }
    guard let display = row.double("ZDISPLAYDATEDATE"),
          display.rounded() == floating.rounded() else { return raw }
    if raw.rounded() == floating.rounded() { return raw }
    if hasTimeZoneColumn, hasAbsoluteAlarm?() == true { return raw }
    return floating
}

/// Built once: a batch read converts every timed row, and constructing a Calendar per row
/// dominated `export` on a large store.
private let utcCalendar: Calendar = {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    return utc
}()

/// The instant whose local clock reading equals `raw`'s UTC clock reading.
private func wallClockReading(_ raw: Double, calendar: Calendar) -> Double {
    let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
    let wall = utcCalendar.dateComponents(fields, from: Date(timeIntervalSince1970: raw + AppleEpoch.offset))
    guard let local = calendar.date(from: wall) else { return raw }
    return AppleEpoch.toTs(local)
}
