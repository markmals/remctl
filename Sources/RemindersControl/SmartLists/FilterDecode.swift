import Foundation

let supportedPriorities: Set<String> = ["low", "medium", "high"]
let supportedVehicles: Set<String> = ["connected", "disconnected"]

/// Result of decode_smart_list_filter_blob.
public struct FilterDecodeResult {
    public var encoding: String?
    public var payload: JSONValue?              // raw filter JSON (order-preserved)
    public var summary: [(String, JSONValue)]?  // ordered summary object
    public var error: String?
}

// MARK: - JSONValue inspection helpers

private extension JSONValue {
    var asObject: [(String, JSONValue)]? { if case let .object(p) = self { return p }; return nil }
    var asArray: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    var asStr: String? { if case let .string(s) = self { return s }; return nil }
    var asBool: Bool? { if case let .bool(b) = self { return b }; return nil }
    func get(_ key: String) -> JSONValue? { asObject?.first(where: { $0.0 == key })?.1 }
    var objectKeys: [String]? { asObject?.map { $0.0 } }
    var isStringArray: Bool { asArray?.allSatisfy { $0.asStr != nil } ?? false }
    var stringArray: [String] { asArray?.compactMap { $0.asStr } ?? [] }
}

/// Port of decode_smart_list_filter_blob.
public func decodeSmartListFilterBlob(_ blob: Data?) -> FilterDecodeResult {
    guard let blob, !blob.isEmpty else { return FilterDecodeResult(encoding: nil, payload: nil, summary: nil, error: nil) }
    let stripped = stripLeadingWhitespace(blob)
    if stripped.first == 0x7B { // '{'
        guard let payload = OrderedJSON.parse(blob), case .object = payload else {
            return FilterDecodeResult(encoding: nil, payload: nil, summary: nil, error: "Smart list filter JSON must be an object")
        }
        return FilterDecodeResult(encoding: "json", payload: payload, summary: summarizeSmartListFilter(payload), error: nil)
    }
    if let archived = extractKeyedArchiveJSON(blob) {
        guard let payload = OrderedJSON.parse(archived), case .object = payload else {
            return FilterDecodeResult(encoding: nil, payload: nil, summary: nil, error: "Smart list filter JSON must be an object")
        }
        return FilterDecodeResult(encoding: "keyed_archive_json", payload: payload, summary: summarizeSmartListFilter(payload), error: nil)
    }
    return FilterDecodeResult(encoding: nil, payload: nil, summary: nil, error: "unsupported filter blob")
}

private func stripLeadingWhitespace(_ data: Data) -> Data {
    var i = data.startIndex
    while i < data.endIndex, data[i] == 0x20 || data[i] == 0x09 || data[i] == 0x0A || data[i] == 0x0D { i = data.index(after: i) }
    return data[i...]
}

/// Best-effort NSKeyedArchiver `$top.root -> objects[root].data -> bytes` extraction.
/// PropertyListSerialization represents bplist UIDs opaquely; we resolve via NSNumber when possible.
private func extractKeyedArchiveJSON(_ data: Data) -> Data? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let archive = plist as? [String: Any],
          let objects = archive["$objects"] as? [Any],
          let top = archive["$top"] as? [String: Any] else { return nil }
    func uidIndex(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    guard let rootIdx = uidIndex(top["root"]), rootIdx < objects.count,
          let root = objects[rootIdx] as? [String: Any],
          let dataIdx = uidIndex(root["data"]), dataIdx < objects.count else { return nil }
    return objects[dataIdx] as? Data
}

/// Port of summarize_smart_list_filter. Returns the ordered summary object or nil.
public func summarizeSmartListFilter(_ payload: JSONValue?) -> [(String, JSONValue)]? {
    guard let payload, let pairs = payload.asObject else { return nil }
    let keys = pairs.map { $0.0 }.sorted()
    func keysJSON() -> JSONValue { .array(keys.map { .string($0) }) }

    if pairs.isEmpty {
        return [("kind", .string("all")), ("description", .string("All reminders")), ("supported", .bool(true)), ("keys", .array([]))]
    }
    if pairs.count == 1, pairs[0].0 == "flagged", pairs[0].1.asBool == true {
        return [("kind", .string("flagged")), ("description", .string("Flagged reminders")), ("supported", .bool(true)), ("keys", .array([.string("flagged")]))]
    }
    let operation = payload.get("operation")?.asStr
    let withoutOp = pairs.filter { $0.0 != "operation" }
    // pure priorities
    if withoutOp.count == 1, withoutOp[0].0 == "priorities",
       let prios = withoutOp[0].1.asArray, !prios.isEmpty,
       prios.allSatisfy({ if let s = $0.asStr { return supportedPriorities.contains(s) } else { return false } }) {
        let names = prios.compactMap { $0.asStr }
        var k: [JSONValue] = [.string("priorities")]
        if operation != nil { k.append(.string("operation")) }
        return [("kind", .string("priority")), ("description", .string("Priority: \(names.joined(separator: ", "))")),
                ("supported", .bool(true)), ("priorities", .array(names.map { .string($0) })), ("keys", .array(k))]
    }
    var parts: [[(String, JSONValue)]] = []
    var unsupported: [[(String, JSONValue)]] = []
    for (key, value) in withoutOp {
        let summary = summarizeFilterFamily(key, value)
        if (summary.first(where: { $0.0 == "supported" })?.1.asBool) == true { parts.append(summary) }
        else { unsupported.append(summary) }
    }
    func desc(_ s: [(String, JSONValue)]) -> String { s.first(where: { $0.0 == "description" })?.1.asStr ?? "" }
    if !parts.isEmpty && unsupported.isEmpty {
        let match = ["and": "all", "or": "any"][operation ?? ""] ?? "all"
        var description = parts.map(desc).joined(separator: "; ")
        if parts.count > 1 || operation == "or" { description = "Match \(match): \(description)" }
        let kind = parts.count > 1 ? "compound" : (parts[0].first(where: { $0.0 == "kind" })?.1.asStr ?? "compound")
        return [("kind", .string(kind)), ("description", .string(description)), ("supported", .bool(true)),
                ("match", .string(match)), ("filters", .array(parts.map { .object($0) })), ("keys", keysJSON())]
    }
    let anyNonMaterializing = unsupported.contains { ($0.first(where: { $0.0 == "materializes" })?.1.asBool) == false }
    return [("kind", .string("unsupported")), ("description", .string("Unsupported custom filter")),
            ("supported", .bool(false)),
            ("materializes", anyNonMaterializing ? .bool(false) : .null),
            ("filters", .array((parts + unsupported).map { .object($0) })), ("keys", keysJSON())]
}

/// Port of _summarize_filter_family.
public func summarizeFilterFamily(_ key: String, _ value: JSONValue) -> [(String, JSONValue)] {
    func unsupported() -> [(String, JSONValue)] {
        [("kind", .string(key)), ("description", .string("Unsupported \(key) filter")), ("supported", .bool(false))]
    }
    if key == "flagged", value.asBool == true {
        return [("kind", .string("flagged")), ("description", .string("Flagged reminders")), ("supported", .bool(true))]
    }
    if key == "priorities", let arr = value.asArray, !arr.isEmpty,
       arr.allSatisfy({ if let s = $0.asStr { return supportedPriorities.contains(s) } else { return false } }) {
        let names = arr.compactMap { $0.asStr }
        return [("kind", .string("priority")), ("description", .string("Priority: \(names.joined(separator: ", "))")),
                ("supported", .bool(true)), ("priorities", .array(names.map { .string($0) }))]
    }
    if key == "hashtags", let obj = value.asObject {
        let v = value
        if obj.count == 1, obj[0].0 == "any", obj[0].1.asStr == "" {
            return [("kind", .string("tags")), ("description", .string("Any tag")), ("supported", .bool(true))]
        }
        if obj.count == 1, obj[0].0 == "untagged", obj[0].1.asStr == "" {
            return [("kind", .string("tags")), ("description", .string("Untagged only")), ("supported", .bool(true))]
        }
        let hashtags = v.get("hashtags")
        if let list = hashtags?.asArray, hashtags?.isStringArray == true {
            let names = list.compactMap { $0.asStr }
            return [("kind", .string("tags")), ("description", .string("Legacy selected tags: \(names.joined(separator: ", "))")),
                    ("supported", .bool(false)), ("tags", .array(names.map { .string($0) })),
                    ("tagMatch", .string("all")), ("materializes", .bool(false))]
        }
        if let h = hashtags?.asObject {
            let include = hashtags?.get("include")?.stringArray ?? []
            let exclude = hashtags?.get("exclude")?.stringArray ?? []
            let op = hashtags?.get("operation")?.asStr
            let includeOK = hashtags?.get("include") == nil || hashtags?.get("include")?.isStringArray == true
            let excludeOK = hashtags?.get("exclude") == nil || hashtags?.get("exclude")?.isStringArray == true
            if (op == "and" || op == "or"), includeOK, excludeOK {
                let match = op == "or" ? "any" : "all"
                var bits: [String] = []
                if !include.isEmpty { bits.append("include \(include.joined(separator: ", "))") }
                if !exclude.isEmpty { bits.append("exclude \(exclude.joined(separator: ", "))") }
                return [("kind", .string("tags")), ("description", .string("Tags \(match) selected: \(bits.joined(separator: ", "))")),
                        ("supported", .bool(true)), ("tags", .array(include.map { .string($0) })),
                        ("excludeTags", .array(exclude.map { .string($0) })), ("tagMatch", .string(match))]
            }
            _ = h
        }
    }
    if key == "date", value.asObject != nil { return summarizeDateFilter(value) }
    if key == "time", let obj = value.asObject {
        for (timeKey, label) in [("morning", "Morning"), ("afternoon", "Afternoon"), ("evening", "Evening"), ("night", "Night"), ("noTime", "No time")] {
            if obj.count == 1, obj[0].0 == timeKey, obj[0].1.asStr == "" {
                return [("kind", .string("time")), ("description", .string(label)), ("supported", .bool(true)), ("time", .string(timeKey))]
            }
        }
    }
    if key == "location", value.asObject != nil {
        if let vehicle = value.get("vehicle")?.asStr, supportedVehicles.contains(vehicle) {
            return [("kind", .string("location")),
                    ("description", .string(vehicle == "connected" ? "Getting in the car" : "Getting out of the car")),
                    ("supported", .bool(true)), ("vehicle", .string(vehicle))]
        }
        if let location = value.get("location"), location.asObject != nil {
            let title = location.get("title")?.asStr ?? "Specific location"
            let proximity = location.get("proximity")?.asStr ?? "enter"
            return [("kind", .string("location")), ("description", .string("Location \(proximity): \(title)")),
                    ("supported", .bool(true)), ("location", location)]
        }
    }
    if key == "lists", value.asObject != nil {
        let include = value.get("include")?.stringArray ?? []
        let exclude = value.get("exclude")?.stringArray ?? []
        let operation = value.get("operation")?.asStr
        let includeOK = value.get("include") == nil || value.get("include")?.isStringArray == true
        let excludeOK = value.get("exclude") == nil || value.get("exclude")?.isStringArray == true
        if includeOK, excludeOK, operation == nil || operation == "and" || operation == "or" {
            let match = ["and": "all", "or": "any"][operation ?? ""] ?? "all"
            var bits: [String] = []
            if !include.isEmpty { bits.append("include \(include.count) list(s)") }
            if !exclude.isEmpty { bits.append("exclude \(exclude.count) list(s)") }
            return [("kind", .string("lists")), ("description", .string("Lists \(match): \(bits.joined(separator: ", "))")),
                    ("supported", .bool(true)), ("include", .array(include.map { .string($0) })),
                    ("exclude", .array(exclude.map { .string($0) })), ("listMatch", .string(match))]
        }
    }
    return unsupported()
}

/// Port of _summarize_date_filter.
public func summarizeDateFilter(_ value: JSONValue) -> [(String, JSONValue)] {
    guard let obj = value.asObject else { return unsupportedDate() }
    if obj.count == 1, obj[0].0 == "any", obj[0].1.asStr == "" {
        return [("kind", .string("date")), ("description", .string("Any date")), ("supported", .bool(true)), ("date", .string("any"))]
    }
    if obj.count == 1, obj[0].0 == "noDate", obj[0].1.asStr == "" {
        return [("kind", .string("date")), ("description", .string("No date")), ("supported", .bool(true)), ("date", .string("noDate"))]
    }
    if let today = value.get("today"), let b = today.asBool {
        let label = b ? "Today and include past due" : "Today"
        return [("kind", .string("date")), ("description", .string(label)), ("supported", .bool(true)),
                ("date", .string("today")), ("includePastDue", .bool(b))]
    }
    for (key, label) in [("onDate", "On date"), ("beforeDate", "Before date"), ("afterDate", "After date")] {
        if obj.count == 1, obj[0].0 == key, let s = obj[0].1.asStr {
            return [("kind", .string("date")), ("description", .string("\(label): \(s)")), ("supported", .bool(true)),
                    ("date", .string(key)), ("value", .string(s))]
        }
    }
    if obj.count == 1, obj[0].0 == "dateRange", let range = obj[0].1.asArray, range.count == 2, range.allSatisfy({ $0.asStr != nil }) {
        let a = range[0].asStr!, b = range[1].asStr!
        return [("kind", .string("date")), ("description", .string("Date range: \(a) to \(b)")), ("supported", .bool(true)),
                ("date", .string("dateRange")), ("range", .array(range))]
    }
    if let relative = value.get("relativeRange"), let robj = relative.asObject {
        let rkeys = Set(robj.map { $0.0 })
        if rkeys.isSuperset(of: ["direction", "magnitude", "units"]) {
            let includePastDue = relative.get("includePastDue")?.asBool ?? false
            let suffix = includePastDue ? ", include past due" : ""
            let dir = relative.get("direction")?.asStr ?? ""
            let mag = relative.get("magnitude").map { jsonScalarString($0) } ?? ""
            let units = relative.get("units")?.asStr ?? ""
            return [("kind", .string("date")), ("description", .string("Relative date: \(dir) \(mag) \(units)\(suffix)")),
                    ("supported", .bool(true)), ("date", .string("relativeRange")), ("relativeRange", relative)]
        }
    }
    return unsupportedDate()
}

private func unsupportedDate() -> [(String, JSONValue)] {
    [("kind", .string("date")), ("description", .string("Unsupported date filter")), ("supported", .bool(false))]
}

private func jsonScalarString(_ v: JSONValue) -> String {
    switch v { case .int(let i): return String(i); case .double(let d): return JSONValue.formatDouble(d); case .string(let s): return s; default: return "" }
}
