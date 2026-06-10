import Foundation

/// Pure (no-EventKit) parsers for write-command inputs: due dates, alarms,
/// recurrence specs, and priority names. These mirror the Python `parse_due`,
/// `parse_clock_time`, `parse_recurrence`, `parse_alarm`, and the `add`/`edit`
/// priority maps. All date math is naive-local, using an injected `Calendar`
/// (default `.current`) and `now` for determinism.
public enum WriteParsing {

    // MARK: - Priority

    /// Priority name -> EventKit code. `add` allows short aliases (h/med/m/l);
    /// `edit` does not. nil if unrecognized.
    public static func parsePriority(_ s: String, allowAliases: Bool) -> Int? {
        let key = s.lowercased()
        // edit map (no aliases). remctl:5447
        var map: [String: Int] = ["high": 1, "medium": 5, "low": 9, "none": 0]
        if allowAliases {
            // add map adds short aliases. remctl:5149
            map["h"] = 1
            map["med"] = 5
            map["m"] = 5
            map["l"] = 9
        }
        return map[key]
    }

    // MARK: - Recurrence

    /// Port of `parse_recurrence` (remctl:3991). nil if unparseable.
    public static func parseRecurrenceSpec(_ s: String) -> RecurrenceWrite? {
        // parts = spec.lower().split()  (whitespace split, drops empties)
        let parts = s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard let freq = parts.first else { return nil }
        guard ["daily", "weekly", "monthly", "yearly"].contains(freq) else { return nil }

        if freq == "weekly" && parts.count > 1 {
            guard parts.count == 2 else { return nil }
            // 1=Sun..7=Sat
            let dayMap: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            let tokens = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty, tokens.allSatisfy({ dayMap[$0] != nil }) else { return nil }
            let days = tokens.map { dayMap[$0]! }
            return RecurrenceWrite(frequency: freq, interval: 1, daysOfWeek: days)
        } else if freq == "monthly" && parts.count > 1 {
            guard parts.count == 2 else { return nil }
            let tokens = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty, tokens.allSatisfy({ isAllDigits($0) }) else { return nil }
            let days = tokens.map { Int($0)! }
            guard days.allSatisfy({ $0 >= 1 && $0 <= 31 }) else { return nil }
            return RecurrenceWrite(frequency: freq, interval: 1, daysOfMonth: days)
        } else if parts.count > 1 {
            // daily/yearly take no args; weekly/monthly fall through here only when
            // parts.count > 1 was already handled above, so this catches daily/yearly extras.
            return nil
        }
        return RecurrenceWrite(frequency: freq, interval: 1)
    }

    // MARK: - Alarm

    private static let alarmClearKeywords: Set<String> = ["clear", "none", "off", "remove", "delete"]

    /// Port of `parse_alarm` (remctl:4041), returning a structured `AlarmWrite`.
    /// "15m"/"2h"/"1d" -> .relativeOffset(-seconds); ISO / `yyyy-MM-dd HH:mm` -> .absolute.
    /// If `allowClear`, clear-keywords (clear/none/off/remove/delete) -> .clear (mirrors
    /// `alarm_clear_requested`, remctl:4064). nil if unparseable.
    public static func parseAlarmSpec(_ s: String, allowClear: Bool = false, calendar: Calendar = .current) -> AlarmWrite? {
        let sl = s.lowercased().trimmingCharacters(in: .whitespaces)
        if sl.isEmpty { return nil }
        if allowClear && alarmClearKeywords.contains(sl) {
            return .clear
        }
        // ^(\d+)(m|min|h|hr|d)$
        if let m = firstMatch(in: sl, pattern: #"^(\d+)(m|min|h|hr|d)$"#) {
            let n = Int(m[1])!
            let unit = m[2]
            let seconds: TimeInterval
            switch unit {
            case "m", "min": seconds = TimeInterval(n) * 60
            case "h", "hr": seconds = TimeInterval(n) * 3600
            case "d": seconds = TimeInterval(n) * 86400
            default: return nil
            }
            return .relativeOffset(-seconds)
        }
        // Absolute ISO datetime: %Y-%m-%dT%H:%M, %Y-%m-%d %H:%M, %Y-%m-%dT%H:%M:%S
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            if let d = strptime(trimmed, format: fmt, calendar: calendar) {
                return .absolute(d)
            }
        }
        return nil
    }

    // MARK: - Clock time

    /// Port of `parse_clock_time` (remctl:3827). Returns (hour, minute) in 24h, or nil.
    /// Validates: minute <= 59, am/pm hour 1-12, bare hour 0-23.
    static func parseClockTime(_ value: String) -> (Int, Int)? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return nil }
        // ^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$
        guard let m = firstMatch(in: text, pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#, groupCount: 3) else {
            return nil
        }
        var hour = Int(m[1])!
        let minute = m[2].isEmpty ? 0 : Int(m[2])!
        let ampm = m[3]
        if minute > 59 { return nil }
        if !ampm.isEmpty {
            if hour < 1 || hour > 12 { return nil }
            if ampm == "pm" && hour < 12 { hour += 12 }
            if ampm == "am" && hour == 12 { hour = 0 }
        } else if hour > 23 {
            return nil
        }
        return (hour, minute)
    }

    // MARK: - Due date

    private static let daysMap: [String: Int] = [
        // Python weekday(): Monday=0..Sunday=6
        "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
        "friday": 4, "saturday": 5, "sunday": 6,
        "mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6,
    ]

    /// Port of `parse_due` (remctl:3886). Natural-language + ISO due-date grammar.
    /// `now`/`calendar` injected for determinism (Python uses local datetime.now()).
    /// After the explicit grammar, falls back to NSDataDetector for phrases the
    /// explicit grammar misses. nil if unparseable.
    public static func parseDue(_ s: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        if s.isEmpty { return nil }
        let sl = s.lowercased().trimmingCharacters(in: .whitespaces)
        if sl.isEmpty { return nil }

        // today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        let today = calendar.startOfDay(for: now)
        // pyWeekday: Monday=0..Sunday=6 (matches Python .weekday())
        let pyWeekday = pythonWeekday(of: today, calendar: calendar)

        // Exact shortcuts
        if sl == "today" { return today }
        if sl == "tomorrow" { return addDays(1, to: today, calendar: calendar) }
        if sl == "eod" { return setTime(hour: 17, minute: 0, on: today, calendar: calendar) }
        if sl == "eow" {
            var daysAhead = 4 - pyWeekday // Friday = 4
            if daysAhead <= 0 { daysAhead += 7 }
            return addDays(daysAhead, to: today, calendar: calendar)
        }

        // "today at 3pm", "tomorrow 15:00"  ^(today|tomorrow)(?:\s+at)?\s+(.+)$
        if let m = firstMatch(in: sl, pattern: #"^(today|tomorrow)(?:\s+at)?\s+(.+)$"#) {
            let dayName = m[1]
            if let (hour, minute) = parseClockTime(m[2]) {
                let base = dayName == "today" ? today : addDays(1, to: today, calendar: calendar)
                return setTime(hour: hour, minute: minute, on: base, calendar: calendar)
            }
            // If clock invalid, fall through (Python does not return here).
        }

        // "tonight at 11"  ^tonight(?:\s+at)?\s+(.+)$
        if let m = firstMatch(in: sl, pattern: #"^tonight(?:\s+at)?\s+(.+)$"#) {
            let timeText = m[1]
            if let (h, minute) = parseClockTime(timeText) {
                var hour = h
                // bare 1-11 (no am/pm) -> +12
                if !hasWordBoundaryAmPm(timeText) && hour >= 1 && hour <= 11 {
                    hour += 12
                }
                var dt = setTime(hour: hour, minute: minute, on: today, calendar: calendar)
                if dt <= now { dt = addDays(1, to: dt, calendar: calendar) }
                return dt
            }
        }

        // Relative: +3d, +1w, +2m, +2h  ^[+]?(\d+)([dwmh])$
        if let m = firstMatch(in: sl, pattern: #"^[+]?(\d+)([dwmh])$"#) {
            let n = Int(m[1])!
            switch m[2] {
            case "d": return addDays(n, to: today, calendar: calendar)
            case "w": return addDays(n * 7, to: today, calendar: calendar)
            case "h": return addHours(n, to: now, calendar: calendar)
            case "m": return addDays(n * 30, to: today, calendar: calendar)
            default: break
            }
        }

        // "[next|this] <weekday> [at <time>]"  ^(?:(next|this)\s+)?(\w+)(?:\s+(?:at\s+)?(.+))?$
        if let m = firstMatch(in: sl, pattern: #"^(?:(next|this)\s+)?(\w+)(?:\s+(?:at\s+)?(.+))?$"#, groupCount: 3) {
            let qualifier = m[1]   // "" if absent
            let dayName = m[2]
            let timeText = m[3]    // "" if absent
            if let target = daysMap[dayName] {
                var daysAhead = ((target - pyWeekday) % 7 + 7) % 7
                if qualifier == "next" && daysAhead == 0 { daysAhead = 7 }
                var dt = addDays(daysAhead, to: today, calendar: calendar)
                if !timeText.isEmpty {
                    guard let (hour, minute) = parseClockTime(timeText) else { return nil }
                    dt = setTime(hour: hour, minute: minute, on: dt, calendar: calendar)
                    if qualifier != "next" && dt <= now {
                        dt = addDays(7, to: dt, calendar: calendar)
                    }
                }
                return dt
            }
        }

        // "in N days/weeks/hours/months"  ^in\s+(\d+)\s+(day|days|week|weeks|hour|hours|month|months)$
        if let m = firstMatch(in: sl, pattern: #"^in\s+(\d+)\s+(day|days|week|weeks|hour|hours|month|months)$"#) {
            let n = Int(m[1])!
            let unit = m[2]
            if unit.contains("day") { return addDays(n, to: today, calendar: calendar) }
            if unit.contains("week") { return addDays(n * 7, to: today, calendar: calendar) }
            if unit.contains("hour") { return addHours(n, to: now, calendar: calendar) }
            if unit.contains("month") { return addDays(n * 30, to: today, calendar: calendar) }
        }

        // ISO formats (parsed against the original trimmed string, case preserved)
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            if let d = strptime(trimmed, format: fmt, calendar: calendar) {
                return d
            }
        }

        // Best-effort natural-language fallback (replaces Python's parsedatetime branch).
        if let d = dataDetectorDate(trimmed, now: now, calendar: calendar) {
            return d
        }

        return nil
    }

    // MARK: - Completion date

    /// Port of `parse_completion_date` (remctl:4641, upstream aba7cf5). Strict —
    /// COMPLETION_DATE_RE is ^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?$ —
    /// then parsed naive-local. No natural-language forms.
    public static func parseCompletionDate(_ value: String, calendar: Calendar = .current) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard firstMatch(in: text, pattern: #"^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?$"#, groupCount: 0) != nil else {
            return nil
        }
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            if let d = strptime(normalized, format: fmt, calendar: calendar) { return d }
        }
        return nil
    }

    // MARK: - All-day detection

    /// Port of `due_spec_is_all_day` (remctl:4287, upstream 6755b8e): true when the
    /// due-date TEXT names a day without a clock time. Branch order mirrors the
    /// Python source; weekday lookup reuses `daysMap` (Python WEEKDAY_MAP).
    public static func dueSpecIsAllDay(_ s: String) -> Bool {
        if s.isEmpty { return false }
        let sl = s.lowercased().trimmingCharacters(in: .whitespaces)
        if ["today", "tomorrow", "eow"].contains(sl) { return true }
        if sl == "eod" { return false }
        if firstMatch(in: s.trimmingCharacters(in: .whitespaces), pattern: #"^\d{4}-\d{2}-\d{2}$"#, groupCount: 0) != nil {
            return true
        }
        if let m = firstMatch(in: sl, pattern: #"^[+]?(\d+)([dwmh])$"#) {
            return ["d", "w", "m"].contains(m[2])
        }
        if let m = firstMatch(in: sl, pattern: #"^in\s+(\d+)\s+(day|days|week|weeks|hour|hours|month|months)$"#) {
            return !["hour", "hours"].contains(m[2])
        }
        if let m = firstMatch(in: sl, pattern: #"^(?:(next|this)\s+)?(\w+)(?:\s+(?:at\s+)?(.+))?$"#, groupCount: 3) {
            return daysMap[m[2]] != nil && m[3].isEmpty
        }
        return false
    }

    // MARK: - Helpers

    private static func isAllDigits(_ s: String) -> Bool {
        return !s.isEmpty && s.allSatisfy { $0.isNumber && $0.isASCII }
    }

    /// Python datetime.weekday(): Monday=0 .. Sunday=6.
    private static func pythonWeekday(of date: Date, calendar: Calendar) -> Int {
        // Calendar.component(.weekday): Sunday=1 .. Saturday=7.
        let w = calendar.component(.weekday, from: date)
        // Sunday(1)->6, Monday(2)->0, ..., Saturday(7)->5
        return (w + 5) % 7
    }

    private static func addDays(_ n: Int, to date: Date, calendar: Calendar) -> Date {
        return calendar.date(byAdding: .day, value: n, to: date)!
    }

    private static func addHours(_ n: Int, to date: Date, calendar: Calendar) -> Date {
        return calendar.date(byAdding: .hour, value: n, to: date)!
    }

    /// Replace hour/minute (seconds=0) on the given date's day, like Python `.replace(hour=, minute=)`.
    private static func setTime(hour: Int, minute: Int, on date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.nanosecond = 0
        return calendar.date(from: comps)!
    }

    /// Whether the time text contains a standalone "am"/"pm" token (Python \b...\b).
    private static func hasWordBoundaryAmPm(_ text: String) -> Bool {
        return firstMatch(in: text.lowercased(), pattern: #"\b(?:am|pm)\b"#, groupCount: 0) != nil
    }

    /// strptime-style strict parse: requires the WHOLE string to match the format,
    /// in the injected calendar's time zone, naive-local.
    private static func strptime(_ s: String, format: String, calendar: Calendar) -> Date? {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = calendar.timeZone
        df.dateFormat = format
        df.isLenient = false
        return df.date(from: s)
    }

    /// NSDataDetector best-effort fallback for natural-language phrases the explicit
    /// grammar misses (design §4).
    ///
    /// **Intentionally now-independent**: NSDataDetector has no reference-date API, so it
    /// resolves under-specified phrases (e.g. "12:30am") against the real system clock.
    /// The injected `now`/`calendar` govern only the explicit grammar above, which covers
    /// all parity-critical cases. The `_ = now; _ = calendar` lines below are deliberate —
    /// they are not a bug; they silence the "unused parameter" warning while making this
    /// design decision visible at the call site.
    private static func dataDetectorDate(_ s: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = detector.firstMatch(in: s, options: [], range: range), match.resultType == .date else {
            return nil
        }
        // Only accept when the detector consumed the WHOLE input. This mirrors the
        // intent of the optional `parsedatetime` branch (parse a standalone phrase)
        // and prevents picking up an incidental time substring out of a string the
        // explicit grammar already handled-and-rejected (e.g. "today at 25:00").
        guard match.range == range else { return nil }
        _ = now; _ = calendar   // intentional — see doc-comment above
        return match.date
    }

    /// Returns capture groups [full, g1, g2, ...] for the first match, with missing
    /// optional groups rendered as "". nil if no match. `groupCount` is the minimum
    /// number of capture groups to return (excluding group 0); the result is padded
    /// with "" so callers can index safely regardless of the pattern's group count.
    private static func firstMatch(in s: String, pattern: String, groupCount: Int = 2) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range) else { return nil }
        var groups: [String] = []
        let upper = max(groupCount, m.numberOfRanges - 1)
        for i in 0...upper {
            if i < m.numberOfRanges {
                let r = m.range(at: i)
                if r.location != NSNotFound, let rr = Range(r, in: s) {
                    groups.append(String(s[rr]))
                } else {
                    groups.append("")
                }
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
