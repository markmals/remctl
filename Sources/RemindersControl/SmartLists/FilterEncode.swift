import Foundation

// Smart-list filter ENCODE pipeline (P15) — the inverse of the Phase-1 decode.
//
// Pure, no live ReminderKit. Ports remctl_smart_lists.py:
//   build_supported_filter_payload / _build_tag_filter / _build_date_filter /
//   _build_time_filter / _build_lists_filter / _build_location_filter /
//   encode_supported_filter_payload / normalize_match_operation / normalize_priorities /
//   normalize_filter_date / normalize_relative_range
// plus the `remctl` CLI glue:
//   smart_list_filter_payload_from_args (~4479) / validate_materializing_smart_list_args (~4455) /
//   smart_list_filter_changes_from_args (~4526) / _smart_list_csv_values /
//   _load_smart_list_filter_json / _resolve_smart_list_filter_list_ids.
//
// Byte-parity goal: bytes emitted here MUST round-trip back through
// decodeSmartListFilterBlob/summarizeSmartListFilter (FilterDecode.swift). Filter bytes use
// the space-free compact serializer (Python separators=(",",":")).

// MARK: - Supported-constant tables (remctl_smart_lists.py:11-33)

/// match keyword → operation. all/and → "and"; any/or → "or".
let supportedMatchOperations: [String: String] = ["all": "and", "any": "or", "and": "and", "or": "or"]
let supportedTimeFilters: Set<String> = ["morning", "afternoon", "evening", "night", "no-time", "noTime"]
let supportedRelativeDirections: [String: String] = [
    "in-next": "inNext", "innext": "inNext", "inNext": "inNext", "next": "inNext",
    "in-past": "inPast", "inpast": "inPast", "inPast": "inPast", "past": "inPast",
]
let supportedRelativeUnits: Set<String> = ["minute", "hour", "day", "week", "month", "year"]
let supportedProximities: [String: String] = [
    "enter": "enter", "arrive": "enter", "arriving": "enter",
    "leave": "leave", "leaving": "leave", "exit": "leave",
]

// MARK: - Error

/// Raised when a requested smart list filter is not supported. Rendered as "Error: <message>".
public struct SmartListFilterError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var description: String { message }
}

// MARK: - Parsed filter-flag values (P16 populates this from the CLI)

/// Holds the parsed `--filter-*` flag values for a smart-list-create/edit invocation.
/// Field names mirror the argparse attribute names used by the Python CLI glue.
public struct SmartListFilterArgs {
    public var match: String                       // "all"/"any"  (default "all")
    public var filterJSON: String?                 // --filter-json  (inline or @path)
    public var flagged: Bool
    public var priority: String?                   // CSV
    public var tags: String?                       // CSV
    public var tagMatch: String                    // "all"/"any"  (default "any")
    public var anyTag: Bool
    public var untagged: Bool
    public var date: String?                       // "any"/"today"/"no-date"
    public var dateTodayIncludePastDue: Bool
    public var dateOn: String?
    public var dateBefore: String?
    public var dateAfter: String?
    public var dateRange: String?                  // "START,END" or "START..END"
    public var dateRelative: String?               // "direction:magnitude:unit[:past-due]"
    public var time: String?                       // morning/afternoon/evening/night/no-time
    public var includeList: [String]               // list names (each may be CSV)
    public var excludeList: [String]
    public var includeListId: [Int]
    public var excludeListId: [Int]
    public var listMatch: String?                  // "all"/"any"
    public var vehicle: String?                    // "connected"/"disconnected"
    public var locationTitle: String?
    public var latitude: Double?
    public var longitude: Double?
    public var radius: Double?                     // default 100 when a specific location is given
    public var proximity: String?                  // enter/leave + synonyms (default "enter")

    public init(
        match: String = "all",
        filterJSON: String? = nil,
        flagged: Bool = false,
        priority: String? = nil,
        tags: String? = nil,
        tagMatch: String = "any",
        anyTag: Bool = false,
        untagged: Bool = false,
        date: String? = nil,
        dateTodayIncludePastDue: Bool = false,
        dateOn: String? = nil,
        dateBefore: String? = nil,
        dateAfter: String? = nil,
        dateRange: String? = nil,
        dateRelative: String? = nil,
        time: String? = nil,
        includeList: [String] = [],
        excludeList: [String] = [],
        includeListId: [Int] = [],
        excludeListId: [Int] = [],
        listMatch: String? = nil,
        vehicle: String? = nil,
        locationTitle: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radius: Double? = nil,
        proximity: String? = nil
    ) {
        self.match = match
        self.filterJSON = filterJSON
        self.flagged = flagged
        self.priority = priority
        self.tags = tags
        self.tagMatch = tagMatch
        self.anyTag = anyTag
        self.untagged = untagged
        self.date = date
        self.dateTodayIncludePastDue = dateTodayIncludePastDue
        self.dateOn = dateOn
        self.dateBefore = dateBefore
        self.dateAfter = dateAfter
        self.dateRange = dateRange
        self.dateRelative = dateRelative
        self.time = time
        self.includeList = includeList
        self.excludeList = excludeList
        self.includeListId = includeListId
        self.excludeListId = excludeListId
        self.listMatch = listMatch
        self.vehicle = vehicle
        self.locationTitle = locationTitle
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.proximity = proximity
    }
}

// MARK: - Normalizers

/// Port of normalize_match_operation (remctl_smart_lists.py:346).
func normalizeMatchOperation(_ match: String?) throws -> String {
    let value = (match ?? "all").trimmingCharacters(in: .whitespaces)
    // Python: `str(match or "all")` — empty string is falsy → "all".
    let key = value.isEmpty ? "all" : value
    guard let op = supportedMatchOperations[key] else {
        throw SmartListFilterError("Smart list match must be all or any.")
    }
    return op
}

/// Port of normalize_priorities (remctl_smart_lists.py:353): dedup, lowercase, order-preserved.
func normalizePriorities(_ priorities: [String]) throws -> [String] {
    var normalized: [String] = []
    for priority in priorities {
        let value = priority.trimmingCharacters(in: .whitespaces).lowercased()
        guard supportedPriorities.contains(value) else {
            throw SmartListFilterError("Unsupported smart list priority. Use low, medium, or high.")
        }
        if !normalized.contains(value) { normalized.append(value) }
    }
    return normalized
}

/// Port of normalize_filter_date (remctl_smart_lists.py:367).
/// Try-order: %Y-%m-%d, %d-%m-%Y, %d/%m/%Y, %Y/%m/%d. Output: %d-%m-%Y.
/// Reproduces Python strptime: accepts non-padded components, validates real calendar dates.
func normalizeFilterDate(_ value: String) throws -> String {
    let text = value.trimmingCharacters(in: .whitespaces)
    if text.isEmpty {
        throw SmartListFilterError("Smart list date cannot be empty.")
    }
    // Each format = (separator, [component-roles]) where role is year/month/day.
    // Try order matches Python exactly.
    let formats: [(sep: Character, roles: [DateComponentRole])] = [
        ("-", [.year, .month, .day]),   // %Y-%m-%d
        ("-", [.day, .month, .year]),   // %d-%m-%Y
        ("/", [.day, .month, .year]),   // %d/%m/%Y
        ("/", [.year, .month, .day]),   // %Y/%m/%d
    ]
    for fmt in formats {
        if let (d, m, y) = parseDateComponents(text, separator: fmt.sep, roles: fmt.roles) {
            return String(format: "%02d-%02d-%04d", d, m, y)
        }
    }
    throw SmartListFilterError("Smart list dates must be YYYY-MM-DD or DD-MM-YYYY.")
}

private enum DateComponentRole { case year, month, day }

/// Strict strptime-style parse for a date with exactly 3 integer components separated by `separator`,
/// mapped to year/month/day by `roles`. Returns (day, month, year) or nil if not a valid calendar date.
/// Mirrors CPython strptime: components must be all-digit (any width 1..N), then validated by the
/// proleptic Gregorian calendar (month 1..12, day 1..days-in-month incl. leap years).
private func parseDateComponents(_ text: String, separator: Character, roles: [DateComponentRole]) -> (day: Int, month: Int, year: Int)? {
    let parts = text.split(separator: separator, omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var year = 0, month = 0, day = 0
    for (part, role) in zip(parts, roles) {
        // strptime requires non-empty, all-decimal digits (no signs/whitespace).
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let v = Int(part) else { return nil }
        switch role {
        case .year: year = v
        case .month: month = v
        case .day: day = v
        }
    }
    // strptime %Y accepts year 1..9999 (datetime range). Reject 0.
    guard year >= 1, year <= 9999 else { return nil }
    guard month >= 1, month <= 12 else { return nil }
    guard day >= 1, day <= daysInMonth(month: month, year: year) else { return nil }
    return (day, month, year)
}

private func daysInMonth(month: Int, year: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    case 2: return isLeapYear(year) ? 29 : 28
    default: return 0
    }
}

private func isLeapYear(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

/// Port of normalize_relative_range (remctl_smart_lists.py:381) for the STRING form
/// "direction:magnitude:unit[:past-due]". Returns an ordered JSON object:
/// {direction, magnitude(STRING), [includePastDue:true,] units}.
func normalizeRelativeRange(_ value: String) throws -> JSONValue {
    let parts = value.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard parts.count == 3 || parts.count == 4 else {
        throw SmartListFilterError("Relative date range must be direction:magnitude:unit[:past-due].")
    }
    let rawDirection = parts[0]
    var magnitude = parts[1]
    var units = parts[2]
    let includePastDue = parts.count == 4 && ["past-due", "include-past-due", "includePastDue", "true"].contains(parts[3])

    guard let direction = supportedRelativeDirections[rawDirection.trimmingCharacters(in: .whitespaces)] else {
        throw SmartListFilterError("Relative date direction must be in-next or in-past.")
    }
    magnitude = magnitude.trimmingCharacters(in: .whitespaces)
    // Python: magnitude.isdigit() and int(magnitude) > 0 — all ASCII digits, positive.
    guard !magnitude.isEmpty, magnitude.allSatisfy({ $0.isASCII && $0.isNumber }), let mag = Int(magnitude), mag > 0 else {
        throw SmartListFilterError("Relative date magnitude must be a positive integer.")
    }
    units = units.trimmingCharacters(in: .whitespaces).lowercased()
    if units.hasSuffix("s") { units = String(units.dropLast()) }
    guard supportedRelativeUnits.contains(units) else {
        throw SmartListFilterError("Relative date unit must be minute, hour, day, week, month, or year.")
    }
    // Key order: direction, magnitude, [includePastDue,] units.
    var payload: [(String, JSONValue)] = [("direction", .string(direction)), ("magnitude", .string(magnitude))]
    if includePastDue { payload.append(("includePastDue", .bool(true))) }
    payload.append(("units", .string(units)))
    return .object(payload)
}

// MARK: - Family builders

/// Port of _build_tag_filter (remctl_smart_lists.py:500). Returns the `hashtags` sub-payload or nil.
private func buildTagFilter(tags rawTags: [String], tagMatch: String, anyTag: Bool, untagged: Bool) throws -> JSONValue? {
    // Python: [str(tag).lstrip("#").strip() for tag in tags if ...truthy after strip]
    let tags = rawTags
        .map { String($0.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let requested = [!tags.isEmpty, anyTag, untagged].filter { $0 }.count
    if requested > 1 {
        throw SmartListFilterError("Pass only one tag filter: --tags, --any-tag, or --untagged.")
    }
    if anyTag { return .object([("any", .string(""))]) }
    if untagged { return .object([("untagged", .string(""))]) }
    if !tags.isEmpty {
        let operation = try normalizeMatchOperation(tagMatch)
        // DOUBLE-nested hashtags: {hashtags:{operation, include, exclude}}
        let inner: [(String, JSONValue)] = [
            ("operation", .string(operation)),
            ("include", .array(tags.map { .string($0) })),
            ("exclude", .array([])),
        ]
        return .object([("hashtags", .object(inner))])
    }
    return nil
}

/// Port of _build_date_filter (remctl_smart_lists.py:515). Returns the `date` sub-payload or nil.
private func buildDateFilter(
    anyDate: Bool, today: Bool, todayIncludePastDue: Bool, noDate: Bool,
    on: String?, before: String?, after: String?, dateRange: String?, relative: String?
) throws -> JSONValue? {
    let requested = [
        anyDate,
        today || todayIncludePastDue,
        noDate,
        on != nil,
        before != nil,
        after != nil,
        dateRange != nil,
        relative != nil,
    ].filter { $0 }.count
    if requested > 1 {
        throw SmartListFilterError("Pass only one date filter.")
    }
    if anyDate { return .object([("any", .string(""))]) }
    if today || todayIncludePastDue { return .object([("today", .bool(todayIncludePastDue))]) }
    if noDate { return .object([("noDate", .string(""))]) }
    if let on { return .object([("onDate", .string(try normalizeFilterDate(on)))]) }
    if let before { return .object([("beforeDate", .string(try normalizeFilterDate(before)))]) }
    if let after { return .object([("afterDate", .string(try normalizeFilterDate(after)))]) }
    if let dateRange {
        // String form: replace ".." with "," then split on ",", strip each part.
        let parts = dateRange.replacingOccurrences(of: "..", with: ",")
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else {
            throw SmartListFilterError("Date range must be START,END.")
        }
        return .object([("dateRange", .array([.string(try normalizeFilterDate(parts[0])), .string(try normalizeFilterDate(parts[1]))]))])
    }
    if let relative {
        return .object([("relativeRange", try normalizeRelativeRange(relative))])
    }
    return nil
}

/// Port of _build_time_filter (remctl_smart_lists.py:568). Returns `{<key>:""}` or nil.
private func buildTimeFilter(_ value: String?) throws -> JSONValue? {
    guard let value else { return nil }
    var normalized = value.trimmingCharacters(in: .whitespaces)
    guard supportedTimeFilters.contains(normalized) else {
        throw SmartListFilterError("Time filter must be morning, afternoon, evening, night, or no-time.")
    }
    if normalized == "no-time" { normalized = "noTime" }
    return .object([(normalized, .string(""))])
}

/// Port of _build_lists_filter (remctl_smart_lists.py:579). `include`/`exclude` are objectUUIDs.
private func buildListsFilter(includeListIds: [String], excludeListIds: [String], listMatch: String?) throws -> JSONValue? {
    let include = includeListIds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let exclude = excludeListIds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !include.isEmpty || !exclude.isEmpty else { return nil }
    var payload: [(String, JSONValue)] = [
        ("include", .array(include.map { .string($0) })),
        ("exclude", .array(exclude.map { .string($0) })),
    ]
    let operation: String
    if listMatch == nil {
        operation = (include.count > 1 && exclude.isEmpty) ? "or" : "and"
    } else {
        operation = try normalizeMatchOperation(listMatch)
    }
    if operation == "or" || include.count > 1 || !exclude.isEmpty {
        payload.append(("operation", .string(operation)))
    }
    return .object(payload)
}

/// A specific-location spec (mirrors the Python `location` dict in smart_list_filter_payload_from_args).
public struct SpecificLocation {
    public var title: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var proximity: String
    public init(title: String, latitude: Double, longitude: Double, radius: Double, proximity: String) {
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.proximity = proximity
    }
}

/// Port of _build_location_filter (remctl_smart_lists.py:594). Returns the `location` sub-payload or nil.
private func buildLocationFilter(vehicle: String?, location: SpecificLocation?) throws -> JSONValue? {
    if let vehicle, !vehicle.isEmpty, location != nil {
        throw SmartListFilterError("Pass either --vehicle or a specific location, not both.")
    }
    if let vehicle, !vehicle.isEmpty {
        let value = vehicle.trimmingCharacters(in: .whitespaces)
        guard supportedVehicles.contains(value) else {
            throw SmartListFilterError("Vehicle filter must be connected or disconnected.")
        }
        return .object([("vehicle", .string(value))])
    }
    if let location {
        let proximityKey = location.proximity.trimmingCharacters(in: .whitespaces)
        guard let proximity = supportedProximities[proximityKey.isEmpty ? "enter" : proximityKey] else {
            throw SmartListFilterError("Specific location proximity must be enter or leave.")
        }
        // Sub-object key order: title, latitude, radius, longitude, proximity.
        let inner: [(String, JSONValue)] = [
            ("title", .string(location.title)),
            ("latitude", .double(location.latitude)),
            ("radius", .double(location.radius)),
            ("longitude", .double(location.longitude)),
            ("proximity", .string(proximity)),
        ]
        return .object([("location", .object(inner))])
    }
    return nil
}

// MARK: - build_supported_filter_payload

/// Port of build_supported_filter_payload (remctl_smart_lists.py:420). Builds the ordered
/// `.object`: `operation` FIRST iff (filters.count>1 OR operation=="or"); then each family in
/// APPEND ORDER: flagged → priorities → hashtags → date → time → lists → location.
///
/// `includeUUIDs`/`excludeUUIDs` are the already-resolved objectUUIDs (P16 resolves names/ids
/// via the list resolver before calling this).
public func buildSupportedFilterPayload(
    match: String = "all",
    flagged: Bool = false,
    priorities: [String] = [],
    tags: [String] = [],
    tagMatch: String = "any",
    anyTag: Bool = false,
    untagged: Bool = false,
    dateAny: Bool = false,
    dateToday: Bool = false,
    dateTodayIncludePastDue: Bool = false,
    dateNoDate: Bool = false,
    dateOn: String? = nil,
    dateBefore: String? = nil,
    dateAfter: String? = nil,
    dateRange: String? = nil,
    dateRelative: String? = nil,
    timeFilter: String? = nil,
    includeUUIDs: [String] = [],
    excludeUUIDs: [String] = [],
    listMatch: String? = nil,
    vehicle: String? = nil,
    location: SpecificLocation? = nil
) throws -> JSONValue {
    var filters: [(String, JSONValue)] = []

    if flagged { filters.append(("flagged", .bool(true))) }

    let normalizedPriorities = try normalizePriorities(priorities)
    if !normalizedPriorities.isEmpty {
        filters.append(("priorities", .array(normalizedPriorities.map { .string($0) })))
    }

    if let tagPayload = try buildTagFilter(tags: tags, tagMatch: tagMatch, anyTag: anyTag, untagged: untagged) {
        filters.append(("hashtags", tagPayload))
    }

    if let datePayload = try buildDateFilter(
        anyDate: dateAny, today: dateToday, todayIncludePastDue: dateTodayIncludePastDue,
        noDate: dateNoDate, on: dateOn, before: dateBefore, after: dateAfter,
        dateRange: dateRange, relative: dateRelative
    ) {
        filters.append(("date", datePayload))
    }

    if let timePayload = try buildTimeFilter(timeFilter) {
        filters.append(("time", timePayload))
    }

    if let listPayload = try buildListsFilter(includeListIds: includeUUIDs, excludeListIds: excludeUUIDs, listMatch: listMatch) {
        filters.append(("lists", listPayload))
    }

    if let locationPayload = try buildLocationFilter(vehicle: vehicle, location: location) {
        filters.append(("location", locationPayload))
    }

    if filters.isEmpty {
        throw SmartListFilterError("Pass at least one smart list filter.")
    }

    let operation = try normalizeMatchOperation(match)
    var payload: [(String, JSONValue)] = []
    if filters.count > 1 || operation == "or" {
        payload.append(("operation", .string(operation)))
    }
    payload.append(contentsOf: filters)
    return .object(payload)
}

// MARK: - CLI glue: _smart_list_csv_values / _load_smart_list_filter_json / resolve list ids

/// Port of _smart_list_csv_values (remctl:4409): flatten list/string values via split_csv.
public func smartListCsvValues(_ values: [String?]) -> [String] {
    var result: [String] = []
    for value in values {
        guard let value else { continue }
        result.append(contentsOf: PrivateParsing.splitCSV(value))
    }
    return result
}

/// Port of _load_smart_list_filter_json (remctl:4421). `@path` reads a file; otherwise inline.
/// Must parse to a JSON object (order preserved via OrderedJSON). Returns nil when value is empty.
public func loadSmartListFilterJSON(_ value: String?) throws -> JSONValue? {
    guard let value, !value.isEmpty else { return nil }
    var source = value
    if source.hasPrefix("@") {
        let path = String(source.dropFirst())
        do {
            source = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        } catch {
            throw SmartListFilterError("Could not read filter JSON file: \(error.localizedDescription)")
        }
    }
    guard let data = source.data(using: .utf8), let payload = OrderedJSON.parse(data) else {
        throw SmartListFilterError("Invalid filter JSON")
    }
    guard case .object = payload else {
        throw SmartListFilterError("Smart list filter JSON must be an object.")
    }
    return payload
}

/// Port of _resolve_smart_list_filter_list_ids (remctl:4438): map names/ids → objectUUID.
/// list-id resolution first (by Z_PK), then names. Each must yield a non-empty objectUUID.
public func resolveSmartListFilterListIds(store: RemindersStore, names: [String], ids: [Int]) throws -> [String] {
    var resolved: [String] = []
    for listId in ids {
        let ref = try resolveRequiredListTarget(store: store, name: nil, listId: listId)
        guard let uuid = ref.objectUUID, !uuid.isEmpty else {
            throw SmartListFilterError("list id \(listId) has no object UUID.")
        }
        resolved.append(uuid)
    }
    for name in names {
        let ref = try resolveRequiredListTarget(store: store, name: name, listId: nil)
        guard let uuid = ref.objectUUID, !uuid.isEmpty else {
            throw SmartListFilterError("list '\(name)' has no object UUID.")
        }
        resolved.append(uuid)
    }
    return resolved
}

// MARK: - validate_materializing_smart_list_args (remctl:4455)

/// Port of validate_materializing_smart_list_args. SKIPPED entirely when --filter-json is given.
public func validateMaterializingSmartListArgs(_ a: SmartListFilterArgs) throws {
    if let fj = a.filterJSON, !fj.isEmpty { return }
    if a.untagged {
        throw SmartListFilterError("Untagged smart-list writes do not materialize reliably in Reminders.app.")
    }
    if a.date == "no-date" {
        throw SmartListFilterError("No-date smart-list writes do not materialize reliably in Reminders.app.")
    }
    if let dr = a.dateRelative, !dr.isEmpty {
        throw SmartListFilterError("Relative-date smart-list writes do not materialize reliably in Reminders.app.")
    }
    if a.time == "no-time" {
        throw SmartListFilterError("No-time smart-list writes do not materialize reliably in Reminders.app.")
    }
    if a.vehicle == "disconnected" {
        throw SmartListFilterError("Vehicle-disconnected smart-list writes do not materialize reliably in Reminders.app.")
    }

    let includeCount = smartListCsvValues(a.includeList.map { Optional($0) }).count + a.includeListId.count
    let excludeCount = smartListCsvValues(a.excludeList.map { Optional($0) }).count + a.excludeListId.count
    if excludeCount > 0 {
        throw SmartListFilterError("List exclusion filters do not materialize reliably in Reminders.app.")
    }
    if includeCount > 1 {
        throw SmartListFilterError("Reminders.app only materializes one included-list filter at a time.")
    }
    if includeCount > 0, let lm = a.listMatch, !lm.isEmpty {
        throw SmartListFilterError("Do not pass --list-match with a single included list.")
    }
}

// MARK: - smart_list_filter_payload_from_args (remctl:4479)

/// Port of smart_list_filter_payload_from_args. Resolves list refs, validates materialization,
/// and builds the supported payload — OR returns the verbatim --filter-json object.
public func smartListFilterPayloadFromArgs(_ a: SmartListFilterArgs, store: RemindersStore) throws -> JSONValue {
    if let raw = try loadSmartListFilterJSON(a.filterJSON) {
        return raw
    }
    try validateMaterializingSmartListArgs(a)

    var location: SpecificLocation?
    if (a.locationTitle != nil && !a.locationTitle!.isEmpty) || a.latitude != nil || a.longitude != nil {
        // Mirror the Python required-keys check: title, latitude, longitude must be present.
        guard let title = a.locationTitle, let lat = a.latitude, let lon = a.longitude else {
            throw SmartListFilterError("Specific location requires title, latitude, and longitude.")
        }
        location = SpecificLocation(
            title: title, latitude: lat, longitude: lon,
            radius: a.radius ?? 100.0, proximity: a.proximity ?? "enter"
        )
    }

    let includeUUIDs = try resolveSmartListFilterListIds(
        store: store, names: smartListCsvValues(a.includeList.map { Optional($0) }), ids: a.includeListId)
    let excludeUUIDs = try resolveSmartListFilterListIds(
        store: store, names: smartListCsvValues(a.excludeList.map { Optional($0) }), ids: a.excludeListId)

    return try buildSupportedFilterPayload(
        match: a.match,
        flagged: a.flagged,
        priorities: smartListCsvValues([a.priority]),
        tags: smartListCsvValues([a.tags]),
        tagMatch: a.tagMatch,
        anyTag: a.anyTag,
        untagged: a.untagged,
        dateAny: a.date == "any",
        dateToday: a.date == "today",
        dateTodayIncludePastDue: a.dateTodayIncludePastDue,
        dateNoDate: a.date == "no-date",
        dateOn: a.dateOn,
        dateBefore: a.dateBefore,
        dateAfter: a.dateAfter,
        dateRange: a.dateRange,
        dateRelative: a.dateRelative,
        timeFilter: a.time,
        includeUUIDs: includeUUIDs,
        excludeUUIDs: excludeUUIDs,
        listMatch: a.listMatch,
        vehicle: a.vehicle,
        location: location
    )
}

// MARK: - encode_supported_filter_payload (remctl_smart_lists.py:627)

/// Port of encode_supported_filter_payload: re-summarize the payload and REJECT if the summary is
/// nil OR unsupported OR kind=="all"; else serialize with the space-free compact serializer (UTF-8).
public func encodeSupportedFilterPayload(_ payload: JSONValue) throws -> Data {
    let summary = summarizeSmartListFilter(payload)
    let supported = summary?.first(where: { $0.0 == "supported" })?.1
    let kind = summary?.first(where: { $0.0 == "kind" })?.1
    let isSupported: Bool = { if case .bool(true)? = supported { return true } else { return false } }()
    let isAll: Bool = { if case .string("all")? = kind { return true } else { return false } }()
    if summary == nil || !isSupported || isAll {
        throw SmartListFilterError("Unsupported smart list filter shape.")
    }
    let json = payload.serialized(indent: nil, ensureAscii: false, spaceSeparators: false)
    return Data(json.utf8)
}

/// Convenience: build (or load --filter-json) then encode in one call. Mirrors the Python
/// flow `encode_supported_filter_payload(smart_list_filter_payload_from_args(a, db))`.
public func encodeSupportedFilterPayload(_ a: SmartListFilterArgs, store: RemindersStore) throws -> Data {
    let payload = try smartListFilterPayloadFromArgs(a, store: store)
    return try encodeSupportedFilterPayload(payload)
}

// MARK: - smart_list_filter_changes_from_args (remctl:4526)

/// Port of smart_list_filter_changes_from_args. True iff any filter-affecting field is set.
public func smartListFilterChangesFromArgs(_ a: SmartListFilterArgs) -> Bool {
    if let fj = a.filterJSON, !fj.isEmpty { return true }
    if a.flagged { return true }
    if a.anyTag || a.untagged { return true }
    if a.dateTodayIncludePastDue { return true }
    // String fields (None/"" → no change).
    let strings: [String?] = [a.priority, a.tags, a.date, a.dateOn, a.dateBefore, a.dateAfter,
                              a.dateRange, a.dateRelative, a.time, a.vehicle, a.locationTitle]
    if strings.contains(where: { $0 != nil && !$0!.isEmpty }) { return true }
    // List fields ([] → no change).
    if !a.includeList.isEmpty || !a.excludeList.isEmpty { return true }
    if !a.includeListId.isEmpty || !a.excludeListId.isEmpty { return true }
    // latitude / longitude (None → no change).
    if a.latitude != nil || a.longitude != nil { return true }
    return false
}
