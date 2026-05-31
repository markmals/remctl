import Foundation

// Pure helpers for the private-metadata pipeline.
// Ports: parse_early_reminder (remctl:4093), split_csv (remctl:2157),
//        parse_subtask_specs (remctl:2217), normalize_section_id (remctl:2794),
//        normalize_image_paths (remctl:2173).
// Section-resolution (resolve_section_ckid remctl:2803) lives in Queries+SectionResolve.swift.

// MARK: - Early reminder

/// Port of `EARLY_REMINDER_CLEAR_VALUES` (remctl:4067).
private let earlyReminderClearValues: Set<String> = [
    "clear", "none", "off", "never", "0", "0m", "0min",
]

/// Port of `EARLY_REMINDER_UNIT_CODES` (remctl:4068).
/// Keys: m/min/mins/minute/minutes→0, h/hr/hrs/hour/hours→1,
///       d/day/days→2, w/wk/wks/week/weeks→3, mo/mon/month/months→4.
private let earlyReminderUnitCodes: [String: Int] = [
    "m": 0, "min": 0, "mins": 0, "minute": 0, "minutes": 0,
    "h": 1, "hr": 1, "hrs": 1, "hour": 1, "hours": 1,
    "d": 2, "day": 2, "days": 2,
    "w": 3, "wk": 3, "wks": 3, "week": 3, "weeks": 3,
    "mo": 4, "mon": 4, "month": 4, "months": 4,
]

public enum PrivateParsing {

    // MARK: - parseEarlyReminder

    /// Port of `parse_early_reminder` (remctl:4093).
    /// Clear-set keywords (case-insensitive) → `.clear(existingIdentifiers:[])`.
    /// `<count><unit>` → `.set(unit:count:existingIdentifiers:[])` where count is negative.
    /// Invalid → throws `CLIError`.
    public static func parseEarlyReminder(_ s: String) throws -> EarlyReminderWrite {
        let value = s.trimmingCharacters(in: .whitespaces).lowercased()
        if earlyReminderClearValues.contains(value) {
            return .clear(existingIdentifiers: [])
        }
        // Strip optional trailing " before" (e.g. "15 minutes before")
        var stripped = value
        if let range = stripped.range(of: #"\s+before$"#, options: .regularExpression) {
            stripped = String(stripped[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // Match ^(\d+)\s*([a-z]+)$
        guard let match = stripped.range(of: #"^(\d+)\s*([a-z]+)$"#, options: .regularExpression) else {
            throw CLIError("--early-reminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.")
        }
        _ = match  // used to confirm regex matched
        // Extract groups manually
        let regex = try! NSRegularExpression(pattern: #"^(\d+)\s*([a-z]+)$"#)
        let nsValue = stripped as NSString
        guard let m = regex.firstMatch(in: stripped, range: NSRange(location: 0, length: nsValue.length)),
              m.numberOfRanges == 3,
              let digitRange = Range(m.range(at: 1), in: stripped),
              let unitRange = Range(m.range(at: 2), in: stripped) else {
            throw CLIError("--early-reminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.")
        }
        let amount = Int(stripped[digitRange])!
        let unitStr = String(stripped[unitRange])
        guard amount > 0, let unitCode = earlyReminderUnitCodes[unitStr] else {
            throw CLIError("--early-reminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.")
        }
        return .set(unit: unitCode, count: -amount, existingIdentifiers: [])
    }

    // MARK: - splitCSV

    /// Port of `split_csv` (remctl:2157).
    /// Splits on `,`, strips whitespace, removes leading `#` chars, drops empties.
    public static func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" }) }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - normalizeSectionId

    /// Port of `normalize_section_id` (remctl:2794).
    /// If the value contains `/`, strip trailing `/` then take the last path segment.
    /// Returns nil if the value is empty or only slashes.
    public static func normalizeSectionId(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if v.contains("/") {
            let trimmed = v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { return nil }
            // take last segment
            let segment = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
            return segment.isEmpty ? nil : segment
        }
        return v.isEmpty ? nil : v
    }

    // MARK: - normalizeImagePaths

    /// Port of `normalize_image_paths` (remctl:2173).
    /// Expands `~` to the home directory absolute path.
    public static func normalizeImagePaths(_ paths: [String]) -> [String] {
        paths
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).expandingTildeInPath }
    }

    // MARK: - parseSubtaskSpecs

    /// Port of `parse_subtask_specs` (remctl:2217).
    /// Each element is either a bare title string or a JSON object string.
    /// Throws `CLIError` for invalid input.
    public static func parseSubtaskSpecs(_ values: [String]) throws -> [SubtaskSpec] {
        var specs: [SubtaskSpec] = []
        for raw in values.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let spec: [String: Any]
            if raw.hasPrefix("{") {
                // JSON object
                guard let data = raw.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data),
                      let dict = parsed as? [String: Any] else {
                    // Extract parse error message like Python does
                    throw CLIError("invalid --subtask JSON: \(jsonParseErrorMessage(raw)).")
                }
                spec = dict
            } else {
                spec = ["title": raw]
            }

            // title is required
            guard let titleAny = spec["title"],
                  let titleStr = titleAny as? String,
                  !titleStr.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIError("each --subtask requires a non-empty title.")
            }
            let titleNorm = titleStr.trimmingCharacters(in: .whitespaces)

            var result = SubtaskSpec(title: titleNorm)

            // notes
            if spec.keys.contains("notes") {
                if let notes = spec["notes"] {
                    if let notesStr = notes as? String {
                        result.notes = notesStr
                    } else if !(notes is NSNull) {
                        throw CLIError("subtask notes must be a string.")
                    }
                }
            }

            // due — we pass through the raw string; the caller (P12/P13) parses it
            if let dueAny = spec["due"], !(dueAny is NSNull) {
                result.due = "\(dueAny)"
            }

            // priority
            if let prioAny = spec["priority"], !(prioAny is NSNull) {
                let p = "\(prioAny)".lowercased()
                guard ["high", "h", "medium", "med", "m", "low", "l", "none"].contains(p) else {
                    throw CLIError("subtask priority must be high, medium, low, or none.")
                }
                result.priority = p
            }

            // alarm — pass through as raw string
            if let alarmAny = spec["alarm"], !(alarmAny is NSNull) {
                result.alarm = "\(alarmAny)"
            }

            // recurrence — pass through as raw string
            if let recAny = spec["recurrence"], !(recAny is NSNull) {
                result.recurrence = "\(recAny)"
            }

            // earlyReminder / early_reminder
            let earlyAny = spec["earlyReminder"] ?? spec["early_reminder"]
            if let earlyAny, !(earlyAny is NSNull) {
                let earlyStr = "\(earlyAny)"
                // Validate by attempting to parse
                do {
                    _ = try parseEarlyReminder(earlyStr)
                } catch {
                    throw CLIError("subtask earlyReminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.")
                }
                result.earlyReminder = earlyStr
            }

            // urls / url — validate http/https scheme (SSRF guard is in ObjC P1)
            let urlsRaw = spec["urls"] ?? spec["url"]
            let urls = normalizeStringList(urlsRaw, field: "urls")
            for url in urls {
                guard isWebURL(url) else {
                    throw CLIError("--private --subtask url requires an http or https URL.")
                }
            }
            result.urls = urls

            // tags
            let tagsRaw = spec["tags"]
            result.tags = normalizeStringList(tagsRaw, field: "tags")

            // images / image
            let imagesRaw = spec["images"] ?? spec["image"]
            let imagePaths = normalizeStringList(imagesRaw, field: "images")
            result.images = normalizeImagePaths(imagePaths)

            // flagged / urgent
            for field in ["flagged", "urgent"] {
                if let boolAny = spec[field] {
                    let val = try normalizeJSONBool(boolAny, field: field)
                    if field == "flagged" { result.flagged = val }
                    else { result.urgent = val }
                }
            }

            // location fields
            let latAny = spec["latitude"]
            let lonAny = spec["longitude"]
            let locTitle = spec["locationTitle"] ?? spec["location_title"]
            if latAny != nil || lonAny != nil || locTitle != nil {
                guard let latAny, let lonAny, !(latAny is NSNull), !(lonAny is NSNull) else {
                    throw CLIError("subtask location alarms require both latitude and longitude.")
                }
                guard let lat = toDouble(latAny), let lon = toDouble(lonAny) else {
                    throw CLIError("subtask location latitude, longitude, and radius must be numbers.")
                }
                let radRaw = spec["radius"] ?? 100.0
                guard let radius = toDouble(radRaw) else {
                    throw CLIError("subtask location latitude, longitude, and radius must be numbers.")
                }
                guard lat >= -90, lat <= 90 else {
                    throw CLIError("subtask latitude must be between -90 and 90.")
                }
                guard lon >= -180, lon <= 180 else {
                    throw CLIError("subtask longitude must be between -180 and 180.")
                }
                guard radius > 0 else {
                    throw CLIError("subtask radius must be greater than 0.")
                }
                // proximity
                let proximityText: String
                if let proxAny = spec["proximity"] {
                    proximityText = "\(proxAny)".lowercased()
                } else {
                    proximityText = "arriving"
                }
                guard ["arriving", "leaving"].contains(proximityText) else {
                    throw CLIError("subtask proximity must be arriving or leaving.")
                }
                result.latitude = lat
                result.longitude = lon
                result.radius = radius
                result.locationTitle = locTitle.map { "\($0)" } ?? "Location"
                result.proximity = proximityText == "leaving" ? 2 : 1

                // address is unsupported for subtasks
                if let addr = spec["address"], !(addr is NSNull), "\(addr)".isEmpty == false {
                    throw CLIError("subtask location address is not currently supported.")
                }
            }

            specs.append(result)
        }
        return specs
    }

    // MARK: - Private helpers

    /// Port of `normalize_string_list`: for tags uses splitCSV; otherwise strips items.
    private static func normalizeStringList(_ value: Any?, field: String) -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        if let s = value as? String {
            if field == "tags" { return splitCSV(s) }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let arr = value as? [Any] {
            var result: [String] = []
            for item in arr {
                guard let s = item as? String else { continue }
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if field == "tags" { result.append(contentsOf: splitCSV(trimmed)) }
                else { result.append(trimmed) }
            }
            return result
        }
        return []
    }

    /// Port of `normalize_json_bool`.
    private static func normalizeJSONBool(_ value: Any, field: String) throws -> Bool {
        if let b = value as? Bool { return b }
        if value is NSNull { return false }
        if let s = value as? String {
            let low = s.trimmingCharacters(in: .whitespaces).lowercased()
            if ["1", "true", "yes", "on"].contains(low) { return true }
            if ["0", "false", "no", "off"].contains(low) { return false }
        }
        throw CLIError("subtask \(field) must be a boolean.")
    }

    /// Port of `is_web_url`: http or https scheme with a non-empty host.
    private static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func toDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func jsonParseErrorMessage(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8) else { return "unknown error" }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return "unknown error"
        } catch {
            return error.localizedDescription
        }
    }
}
