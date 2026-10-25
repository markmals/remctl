import Foundation

/// The `--recurrence` string grammar (upstream c84fbca): a frequency, an optional `xN`
/// interval token directly after it, then at most one comma list of weekdays (`weekly`) or of
/// day-of-month numbers / Nth-weekday tokens (`monthly`).
extension WriteParsing {

    /// Appended to every "could not parse recurrence" error.
    static let recurrenceGrammarHint = "Use daily, weekly, monthly, yearly, 'weekly mon,wed,fri', 'monthly 1,15', 'monthly 4th-fri', 'monthly last-fri', 'monthly -1-fri', or an interval like 'daily x2' / 'monthly x2 4th-fri'. The xN interval (1-999) must come directly after the frequency, and nth-weekday tokens cannot be mixed with day-of-month numbers. An exported recurrence object is also accepted."

    private static let recurrenceDayTokens: [String: Int] =
        ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    static func parseRecurrenceGrammar(_ spec: String) -> RecurrenceWrite? {
        let parts = spec.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard let frequency = parts.first, ["daily", "weekly", "monthly", "yearly"].contains(frequency) else { return nil }

        var rule = RecurrenceWrite(frequency: frequency, interval: 1)
        var rest = parts.dropFirst()
        if let first = rest.first, let interval = recurrenceInterval(first) {
            rule.interval = interval
            rest = rest.dropFirst()
        }
        guard let list = rest.first else { return rule }
        let tokens = list.split(separator: ",").map(String.init)
        guard rest.count == 1, !tokens.isEmpty else { return nil }

        switch frequency {
        case "weekly":
            guard tokens.allSatisfy({ recurrenceDayTokens[$0] != nil }) else { return nil }
            rule.daysOfWeek = tokens.map { recurrenceDayTokens[$0]! }
        case "monthly":
            if let pinned = nthWeekdays(tokens) {
                rule.daysOfWeek = pinned.map(\.day)
                rule.weekNumbers = pinned.map(\.week)
            } else if let days = daysOfMonth(tokens) {
                rule.daysOfMonth = days
            } else {
                return nil
            }
        default:
            return nil
        }
        return rule
    }

    /// `xN` with N in 1...999. Three ASCII digits at most, so a long digit run can't overflow Int.
    private static func recurrenceInterval(_ token: String) -> Int? {
        guard token.hasPrefix("x") else { return nil }
        let digits = token.dropFirst()
        guard (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), value >= 1 else { return nil }
        return value
    }

    private static func daysOfMonth(_ tokens: [String]) -> [Int]? {
        guard tokens.allSatisfy({ isAllDigits($0) && $0.count <= 2 }) else { return nil }
        let days = tokens.compactMap { Int($0) }
        return days.allSatisfy({ 1...31 ~= $0 }) ? days : nil
    }

    /// `4th-fri`, `last-fri` (= `-1-fri`) and `-1-fri` through `-5-fri`, all or nothing: a list
    /// mixing these with day-of-month numbers is rejected by both branches of the caller.
    private static func nthWeekdays(_ tokens: [String]) -> [(day: Int, week: Int)]? {
        var pinned: [(day: Int, week: Int)] = []
        for token in tokens {
            guard let dash = token.lastIndex(of: "-"),
                  let day = recurrenceDayTokens[String(token[token.index(after: dash)...])],
                  let week = weekOfMonth(token[..<dash]) else { return nil }
            pinned.append((day, week))
        }
        return pinned
    }

    /// `1st`...`5th` with the matching suffix, `last`, or `-1`...`-5`.
    private static func weekOfMonth(_ text: Substring) -> Int? {
        if text == "last" { return -1 }
        if text.hasPrefix("-") {
            guard text.count == 2, let n = Int(text.dropFirst()), 1...5 ~= n else { return nil }
            return -n
        }
        guard text.count == 3, let n = Int(text.prefix(1)), 1...5 ~= n,
              text.dropFirst() == Constants.recurrenceOrdinalSuffixes[n]! else { return nil }
        return n
    }
}
