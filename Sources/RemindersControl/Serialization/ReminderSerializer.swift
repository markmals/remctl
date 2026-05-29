import Foundation

/// Lenient JSON parse mirroring Python `_json_blob`: nil/"" -> nil; invalid -> nil. Returns Foundation Any.
func jsonBlob(_ value: Any?) -> Any? {
    let data: Data
    if let s = value as? String {
        if s.isEmpty { return nil }
        data = Data(s.utf8)
    } else if let d = value as? Data {
        if d.isEmpty { return nil }
        data = d
    } else {
        return nil
    }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// Order-preserving parse of a blob column to JSONValue (for passthrough fields).
func orderedJSONBlob(_ value: String?) -> JSONValue? {
    guard let s = value, !s.isEmpty else { return nil }
    return OrderedJSON.parse(Data(s.utf8))
}

func isEmptyJSON(_ v: JSONValue) -> Bool {
    switch v {
    case .array(let a): return a.isEmpty
    case .object(let o): return o.isEmpty
    case .string(let s): return s.isEmpty
    case .null: return true
    default: return false
    }
}

/// Port of `recurrence_from_row`. Returns ordered key/value pairs or nil. `ts` maps Apple-seconds -> ISO.
public func recurrenceFromRow(_ row: ReminderRow, ts: (Double) -> String?) -> [(String, JSONValue)]? {
    guard let freqRaw = row.int("recurrence_frequency"),
          let freqName = Constants.recurrenceFrequencies[freqRaw] else { return nil }
    // Python: `_row_get(row, "recurrence_interval") or 1` — 0/None/"" all become 1.
    let rawInterval = row.int("recurrence_interval") ?? 0
    let interval = rawInterval == 0 ? 1 : rawInterval
    var out: [(String, JSONValue)] = [("frequency", .string(freqName)), ("interval", .int(interval))]

    // daysOfWeek: detailed passthrough (order-preserved) + derived ints.
    // Python emits both keys whenever days_of_week is truthy (non-empty list).
    if let detailed = orderedJSONBlob(row.string("recurrence_days_of_week")),
       case let .array(items) = detailed, !items.isEmpty {
        out.append(("daysOfWeekDetailed", detailed))
        // derive ints from each object's dayOfTheWeek (skip falsey / non-dict).
        // Python: `if isinstance(item, dict) and item.get("dayOfTheWeek")` — 0 is falsey, skipped.
        let nums: [JSONValue] = items.compactMap { item in
            guard case let .object(pairs) = item,
                  let dow = pairs.first(where: { $0.0 == "dayOfTheWeek" })?.1 else { return nil }
            let n: Int
            switch dow {
            case let .int(i): n = i
            case let .double(d): n = Int(d)
            default: return nil
            }
            guard n != 0 else { return nil }
            return .int(n)
        }
        out.append(("daysOfWeek", .array(nums)))
    }
    for (alias, key) in [("recurrence_days_of_month", "daysOfMonth"),
                         ("recurrence_months_of_year", "monthsOfYear"),
                         ("recurrence_days_of_year", "daysOfYear"),
                         ("recurrence_weeks_of_year", "weeksOfYear"),
                         ("recurrence_set_positions", "setPositions")] {
        if let v = orderedJSONBlob(row.string(alias)), !isEmptyJSON(v) { out.append((key, v)) }
    }
    if let count = row.int("recurrence_count"), count != 0 { out.append(("count", .int(count))) }
    if let end = row.double("recurrence_end_date"), end != 0, let iso = ts(end) { out.append(("endDate", .string(iso))) }
    return out
}

/// Port of `due_date_delta_alerts_from_row`. Returns array of ordered alert objects.
public func dueDateDeltaAlertsFromRow(_ row: ReminderRow, ts: (Double) -> String?) -> [[(String, JSONValue)]] {
    guard let payload = jsonBlob(row.string("ZDUEDATEDELTAALERTSDATA")) as? [String: Any],
          let alerts = payload["dueDateDeltaAlerts"] as? [Any] else { return [] }
    var result: [[(String, JSONValue)]] = []
    for case let alert as [String: Any] in alerts {
        guard let unitRaw = (alert["dueDateDeltaUnit"] as? NSNumber)?.intValue,
              let count = (alert["dueDateDeltaCount"] as? NSNumber)?.intValue else { continue }
        let (singular, plural) = Constants.dueDateDeltaUnits[unitRaw] ?? ("unknown", "unknown")
        let value = abs(count)
        let unitName = value == 1 ? singular : plural
        let direction = count < 0 ? "before" : "after"
        var item: [(String, JSONValue)] = [
            ("unit", .string(unitName)), ("unitCode", .int(unitRaw)), ("count", .int(count)),
            ("value", .int(value)), ("direction", .string(direction)),
            ("label", .string("\(value) \(unitName) \(direction)")),
        ]
        if let id = alert["identifier"] as? String, !id.isEmpty { item.append(("identifier", .string(id))) }
        if let cd = alert["creationDate"] as? NSNumber, let iso = ts(cd.doubleValue) { item.append(("creationDate", .string(iso))) }
        // Python: `if min_version is not None` — includes 0.
        if let mv = alert["minimumSupportedAppVersion"] as? NSNumber { item.append(("minimumSupportedAppVersion", .int(mv.intValue))) }
        result.append(item)
    }
    return result
}
