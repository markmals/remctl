import Foundation

/// Port of attachment_rows_to_json: [{filename, type}] (ordered keys).
public func attachmentRowsToJSON(_ rows: [ReminderRow]) -> [JSONValue] {
    rows.map { row in
        .object([
            ("filename", row.string("ZFILENAME").map { .string($0) } ?? .null),
            ("type", row.string("ZATTACHMENTTYPERAWVALUE").map { .string($0) } ?? .null),
        ])
    }
}

/// Port of _relative_alarm_label.
public func relativeAlarmLabel(_ seconds: Int) -> String {
    let value = abs(seconds)
    var amount = value
    var unitName = "second"
    for (unitSeconds, name) in [(86400, "day"), (3600, "hour"), (60, "minute")] {
        if value != 0 && value % unitSeconds == 0 { amount = value / unitSeconds; unitName = name; break }
    }
    let plural = amount == 1 ? "" : "s"
    let direction = seconds < 0 ? "before due date" : "after due date"
    return "\(amount) \(unitName)\(plural) \(direction)"
}

private func dateComponentsISO(_ comps: [String: Any]) -> String? {
    func intOf(_ k: String, _ def: Int? = nil) -> Int? {
        if let n = comps[k] as? NSNumber { return n.intValue }
        if let s = comps[k] as? String, let i = Int(s) { return i }
        return def
    }
    guard let y = intOf("year"), let mo = intOf("month"), let d = intOf("day") else { return nil }
    let h = intOf("hour", 0) ?? 0, mi = intOf("minute", 0) ?? 0, s = intOf("second", 0) ?? 0
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, mo, d, h, mi, s)
}

/// Port of alarm_rows_to_json: relative / location / absolute / unknown.
public func alarmRowsToJSON(_ rows: [ReminderRow]) -> [JSONValue] {
    rows.map { row in
        var pairs: [(String, JSONValue)] = [("id", .int(row.int("alarm_id") ?? 0))]
        if let interval = row.double("time_interval") {
            let seconds = Int(interval)
            let minutes: JSONValue = (seconds % 60 == 0) ? .int(seconds / 60) : .double(Double(seconds) / 60.0)
            pairs.append(("type", .string("relative")))
            pairs.append(("relativeOffset", .int(seconds)))
            pairs.append(("relativeOffsetMinutes", minutes))
            pairs.append(("label", .string(relativeAlarmLabel(seconds))))
        } else if row.double("latitude") != nil || row.double("longitude") != nil {
            let code = row.int("proximity")
            let rawTitle = row.string("location_title")
            let title = (rawTitle == nil || rawTitle!.isEmpty) ? "Location" : rawTitle!
            func numOrNull(_ k: String) -> JSONValue { row.double(k).map { .double($0) } ?? .null }
            var loc: [(String, JSONValue)] = [
                ("title", .string(title)),
                ("latitude", numOrNull("latitude")),
                ("longitude", numOrNull("longitude")),
                ("radius", numOrNull("radius")),
                ("proximity", .string(code == 2 ? "leaving" : "arriving")),
                ("proximityCode", code.map { .int($0) } ?? .null),
            ]
            if let address = row.string("address"), !address.isEmpty { loc.append(("address", .string(address))) }
            pairs.append(("type", .string("location")))
            pairs.append(("location", .object(loc)))
        } else if let blob = row.blobString("date_components"),
                  let any = jsonBlob(blob) as? [String: Any],
                  let ordered = orderedJSONBlob(blob) {
            pairs.append(("type", .string("absolute")))
            pairs.append(("dateComponents", ordered))
            if let iso = dateComponentsISO(any) { pairs.append(("date", .string(iso))) }
            if let tz = any["timeZone"] as? [String: Any], let id = tz["identifier"] as? String {
                pairs.append(("timeZone", .string(id)))
            }
        } else {
            pairs.append(("type", .string("unknown")))
        }
        return .object(pairs)
    }
}

/// Human label for one serialized alarm object (mirrors cmd_info alarm rendering).
public func alarmHumanLabel(_ alarm: JSONValue) -> String {
    guard case let .object(pairs) = alarm else { return "" }
    let d = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    func s(_ k: String) -> String? { if case let .string(v)? = d[k] { return v }; return nil }
    if s("type") == "location", case let .object(loc)? = d["location"] {
        let l = Dictionary(loc, uniquingKeysWith: { a, _ in a })
        let title = { if case let .string(v)? = l["title"] { return v }; return "Location" }()
        let prox = { if case let .string(v)? = l["proximity"] { return v }; return "" }()
        return "\(title) (\(prox))"
    }
    return s("label") ?? s("date") ?? s("type") ?? ""
}
