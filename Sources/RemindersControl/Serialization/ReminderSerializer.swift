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

/// Port of serialize_reminder. Builds ordered key/value pairs for one reminder.
public func serializeReminder(
    _ row: ReminderRow,
    ts: (Double) -> String?,
    priorityNames: [Int: String],
    section: String? = nil,
    subtaskCounts: [Int: Int] = [:],
    hashtags: [Int: [String]] = [:],
    richLink: (() -> String?)? = nil
) -> [(String, JSONValue)] {
    let pk = row.int("Z_PK") ?? 0
    let subtaskCount = subtaskCounts[pk] ?? 0
    let tags = hashtags[pk] ?? []

    var o: [(String, JSONValue)] = [
        ("id", .int(pk)),
        ("title", row.string("ZTITLE").map { .string($0) } ?? .null),
        ("list", row.string("list_name").map { .string($0) } ?? .null),
        ("completed", .bool((row.int("ZCOMPLETED") ?? 0) != 0)),
        ("flagged", .bool((row.int("ZFLAGGED") ?? 0) != 0)),
        ("urgent", .bool((row.int("ZISURGENTSTATEENABLEDFORCURRENTUSER") ?? 0) != 0)),
        ("priority", .string(priorityNames[row.int("ZPRIORITY") ?? 0] ?? "none")),
        ("subtaskCount", .int(subtaskCount)),
        ("isSubtask", .bool((row.int("ZPARENTREMINDER") ?? 0) != 0)),
    ]
    if let section, !section.isEmpty { o.append(("section", .string(section))) }
    if let notes = row.string("ZNOTES"), !notes.isEmpty { o.append(("notes", .string(notes))) }
    var url = row.string("ZICSURL")
    if (url == nil || url!.isEmpty), let r = richLink?() { url = r }
    if let url, !url.isEmpty { o.append(("url", .string(url))) }
    let due = row.double("ZDUEDATE")
    if let due, due != 0, let iso = ts(due) { o.append(("dueDate", .string(iso))) }
    if let disp = row.double("ZDISPLAYDATEDATE"), disp != 0, disp != due, let iso = ts(disp) {
        o.append(("displayDate", .string(iso)))
    }
    if row.has("ZALLDAY"), let ad = row.int("ZALLDAY") { o.append(("allDay", .bool(ad != 0))) }
    if let c = row.double("ZCREATIONDATE"), c != 0, let iso = ts(c) { o.append(("createdDate", .string(iso))) }
    if let cd = row.double("ZCOMPLETIONDATE"), cd != 0, let iso = ts(cd) { o.append(("completionDate", .string(iso))) }
    if let parent = row.int("ZPARENTREMINDER"), parent != 0 { o.append(("parentID", .int(parent))) }
    if !tags.isEmpty { o.append(("tags", .array(tags.map { .string($0) }))) }
    if let rec = recurrenceFromRow(row, ts: ts) { o.append(("recurrence", .object(rec))) }
    let early = dueDateDeltaAlertsFromRow(row, ts: ts)
    if !early.isEmpty {
        o.append(("earlyReminder", .object(early[0])))
        o.append(("earlyReminders", .array(early.map { .object($0) })))
    }
    if let ck = row.string("ZCKIDENTIFIER"), !ck.isEmpty {
        o.append(("deepLink", .string(Constants.deepLinkReminderPrefix + ck)))
    }
    return o
}

/// Batch serialize. Preloads subtaskCounts + hashtags; binds rich-link url fallback to the store.
/// memberships maps a reminder's ZCKIDENTIFIER -> section display name (empty if none).
public func serializeReminders(_ rows: [ReminderRow], store: RemindersStore,
                               memberships: [String: String] = [:]) -> [[(String, JSONValue)]] {
    let pks = rows.compactMap { $0.int("Z_PK") }
    let (subtaskCounts, hashtags) = store.preloadExtras(pks)
    return rows.map { row in
        let section = row.string("ZCKIDENTIFIER").flatMap { memberships[$0] }
        let pk = row.int("Z_PK") ?? 0
        return serializeReminder(row, ts: { AppleEpoch.ts($0) }, priorityNames: Constants.priorityName,
            section: section, subtaskCounts: subtaskCounts, hashtags: hashtags,
            richLink: { store.richLink(pk: pk) })
    }
}
