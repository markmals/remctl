import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// FilterEncodeTests – the byte-parity guard for the smart-list filter ENCODE
// pipeline (P15), the inverse of the Phase-1 decode.
//
// Two invariants per filter family:
//   1. ROUND-TRIP: encode → decodeSmartListFilterBlob(data) decodes to the expected
//      summary (kind / supported / description).
//   2. BYTE-EXACTNESS: the exact compact no-space JSON string matches the Python
//      encode_supported_filter_payload output (golden strings generated from
//      remctl_smart_lists.py).
//
// Fixture store (for list-uuid resolution):
//   - Work: pk=10, Z_ENT=3, ZCKIDENTIFIER='UUID-A'
//   - Home: pk=11, Z_ENT=3, ZCKIDENTIFIER='UUID-B'
//   - NoCK: pk=12, Z_ENT=3, ZCKIDENTIFIER=NULL
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct FilterEncodeTests {

    // MARK: - Fixture store

    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (10, 3, 'Work', 'UUID-A', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (11, 3, 'Home', 'UUID-B', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZMARKEDFORDELETION)
                VALUES (12, 3, 'NoCK', 0)
            """)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    // MARK: - Helpers

    /// Encode `payload` and assert exact bytes + that it round-trips through the decoder.
    private func assertBytes(_ payload: JSONValue, _ expected: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encodeSupportedFilterPayload(payload)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == expected, "byte mismatch", sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1))
        // Round-trip: the decoder must accept these bytes and produce a summary.
        let decoded = decodeSmartListFilterBlob(data)
        #expect(decoded.summary != nil)
        #expect(decoded.error == nil)
    }

    private func summaryField(_ data: Data, _ key: String) -> JSONValue? {
        decodeSmartListFilterBlob(data).summary?.first(where: { $0.0 == key })?.1
    }

    private func description(_ data: Data) -> String? {
        if case .string(let s)? = summaryField(data, "description") { return s }
        return nil
    }

    private func kind(_ data: Data) -> String? {
        if case .string(let s)? = summaryField(data, "kind") { return s }
        return nil
    }

    private func supported(_ data: Data) -> Bool? {
        if case .bool(let b)? = summaryField(data, "supported") { return b }
        return nil
    }

    // MARK: - flagged

    @Test func flaggedBytesAndRoundTrip() throws {
        let p = try buildSupportedFilterPayload(flagged: true)
        try assertBytes(p, "{\"flagged\":true}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(kind(data) == "flagged")
        #expect(supported(data) == true)
        #expect(description(data) == "Flagged reminders")
    }

    // MARK: - priorities (dedup, order-preserved)

    @Test func prioritiesDedupOrderPreserved() throws {
        let p = try buildSupportedFilterPayload(priorities: ["high", "low", "high"])
        try assertBytes(p, "{\"priorities\":[\"high\",\"low\"]}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(kind(data) == "priority")
        #expect(description(data) == "Priority: high, low")
    }

    @Test func prioritiesBadThrows() {
        #expect(throws: SmartListFilterError.self) {
            _ = try buildSupportedFilterPayload(priorities: ["urgent"])
        }
        do {
            _ = try buildSupportedFilterPayload(priorities: ["urgent"])
        } catch let e as SmartListFilterError {
            #expect(e.message == "Unsupported smart list priority. Use low, medium, or high.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - tags (double-nested hashtags)

    @Test func tagsAllIncludeBytes() throws {
        let p = try buildSupportedFilterPayload(tags: ["work", "home"], tagMatch: "all")
        try assertBytes(p, "{\"hashtags\":{\"hashtags\":{\"operation\":\"and\",\"include\":[\"work\",\"home\"],\"exclude\":[]}}}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(kind(data) == "tags")
        #expect(description(data) == "Tags all selected: include work, home")
    }

    @Test func tagsAnyDefaultBytes() throws {
        let p = try buildSupportedFilterPayload(tags: ["work"])  // tagMatch default "any"
        try assertBytes(p, "{\"hashtags\":{\"hashtags\":{\"operation\":\"or\",\"include\":[\"work\"],\"exclude\":[]}}}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(description(data) == "Tags any selected: include work")
    }

    @Test func anyTagBytes() throws {
        let p = try buildSupportedFilterPayload(anyTag: true)
        try assertBytes(p, "{\"hashtags\":{\"any\":\"\"}}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(description(data) == "Any tag")
    }

    @Test func untaggedBytesPayloadLevel() throws {
        // (encode is allowed; the materialization GUARD is what rejects --untagged)
        let p = try buildSupportedFilterPayload(untagged: true)
        try assertBytes(p, "{\"hashtags\":{\"untagged\":\"\"}}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(description(data) == "Untagged only")
    }

    @Test func multipleTagModesThrows() {
        do {
            _ = try buildSupportedFilterPayload(tags: ["x"], anyTag: true)
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Pass only one tag filter: --tags, --any-tag, or --untagged.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - date variants

    @Test func dateAnyBytes() throws {
        let p = try buildSupportedFilterPayload(dateAny: true)
        try assertBytes(p, "{\"date\":{\"any\":\"\"}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Any date")
    }

    @Test func dateTodayBytes() throws {
        let p = try buildSupportedFilterPayload(dateToday: true)
        try assertBytes(p, "{\"date\":{\"today\":false}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Today")
    }

    @Test func dateTodayIncludePastDueBytes() throws {
        let p = try buildSupportedFilterPayload(dateTodayIncludePastDue: true)
        try assertBytes(p, "{\"date\":{\"today\":true}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Today and include past due")
    }

    @Test func dateNoDateBytes() throws {
        let p = try buildSupportedFilterPayload(dateNoDate: true)
        try assertBytes(p, "{\"date\":{\"noDate\":\"\"}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "No date")
    }

    @Test func dateOnBytes() throws {
        let p = try buildSupportedFilterPayload(dateOn: "2026-04-03")
        try assertBytes(p, "{\"date\":{\"onDate\":\"03-04-2026\"}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "On date: 03-04-2026")
    }

    @Test func dateBeforeAfterBytes() throws {
        let pb = try buildSupportedFilterPayload(dateBefore: "2026-04-03")
        try assertBytes(pb, "{\"date\":{\"beforeDate\":\"03-04-2026\"}}")
        let pa = try buildSupportedFilterPayload(dateAfter: "2026-04-03")
        try assertBytes(pa, "{\"date\":{\"afterDate\":\"03-04-2026\"}}")
    }

    @Test func dateRangeBytes() throws {
        let p = try buildSupportedFilterPayload(dateRange: "2026-01-01,2026-12-31")
        try assertBytes(p, "{\"date\":{\"dateRange\":[\"01-01-2026\",\"31-12-2026\"]}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Date range: 01-01-2026 to 31-12-2026")
    }

    @Test func dateRangeDotDotBytes() throws {
        // ".." form is normalized to ","
        let p = try buildSupportedFilterPayload(dateRange: "2026-01-01..2026-12-31")
        try assertBytes(p, "{\"date\":{\"dateRange\":[\"01-01-2026\",\"31-12-2026\"]}}")
    }

    // MARK: - relativeRange (magnitude is a STRING; key order direction,magnitude,[includePastDue,]units)

    @Test func relativeRangeBytes() throws {
        let p = try buildSupportedFilterPayload(dateRelative: "in-next:3:days")
        try assertBytes(p, "{\"date\":{\"relativeRange\":{\"direction\":\"inNext\",\"magnitude\":\"3\",\"units\":\"day\"}}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Relative date: inNext 3 day")
    }

    @Test func relativeRangeIncludePastDueOrderAndStringMagnitude() throws {
        let p = try buildSupportedFilterPayload(dateRelative: "in-past:2:week:past-due")
        // includePastDue MUST sit between magnitude and units; magnitude is the STRING "2".
        try assertBytes(p, "{\"date\":{\"relativeRange\":{\"direction\":\"inPast\",\"magnitude\":\"2\",\"includePastDue\":true,\"units\":\"week\"}}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Relative date: inPast 2 week, include past due")
    }

    @Test func relativeRangeBadDirectionThrows() {
        do {
            _ = try buildSupportedFilterPayload(dateRelative: "sideways:3:days")
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Relative date direction must be in-next or in-past.")
        } catch { Issue.record("wrong error") }
    }

    @Test func relativeRangeBadMagnitudeThrows() {
        do {
            _ = try buildSupportedFilterPayload(dateRelative: "in-next:0:days")
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Relative date magnitude must be a positive integer.")
        } catch { Issue.record("wrong error") }
    }

    @Test func twoDateFiltersThrows() {
        do {
            _ = try buildSupportedFilterPayload(dateToday: true, dateOn: "2026-01-01")
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Pass only one date filter.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - time

    @Test func timeBytes() throws {
        let p = try buildSupportedFilterPayload(timeFilter: "morning")
        try assertBytes(p, "{\"time\":{\"morning\":\"\"}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Morning")
    }

    @Test func timeNoTimeMapsToCamel() throws {
        let p = try buildSupportedFilterPayload(timeFilter: "no-time")
        try assertBytes(p, "{\"time\":{\"noTime\":\"\"}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "No time")
    }

    @Test func timeBadThrows() {
        do {
            _ = try buildSupportedFilterPayload(timeFilter: "midnight")
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Time filter must be morning, afternoon, evening, night, or no-time.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - lists (operation emission rules)

    @Test func listsSingleIncludeNoOperation() throws {
        let p = try buildSupportedFilterPayload(includeUUIDs: ["UUID-A"])
        try assertBytes(p, "{\"lists\":{\"include\":[\"UUID-A\"],\"exclude\":[]}}")
        #expect(kind(try encodeSupportedFilterPayload(p)) == "lists")
    }

    @Test func listsMultiIncludeOrOperation() throws {
        let p = try buildSupportedFilterPayload(includeUUIDs: ["UUID-A", "UUID-B"])
        try assertBytes(p, "{\"lists\":{\"include\":[\"UUID-A\",\"UUID-B\"],\"exclude\":[],\"operation\":\"or\"}}")
    }

    @Test func listsIncludeExcludeAndOperation() throws {
        let p = try buildSupportedFilterPayload(includeUUIDs: ["UUID-A"], excludeUUIDs: ["UUID-B"])
        try assertBytes(p, "{\"lists\":{\"include\":[\"UUID-A\"],\"exclude\":[\"UUID-B\"],\"operation\":\"and\"}}")
    }

    // MARK: - location (sub-order title,latitude,radius,longitude,proximity)

    @Test func vehicleBytes() throws {
        let p = try buildSupportedFilterPayload(vehicle: "connected")
        try assertBytes(p, "{\"location\":{\"vehicle\":\"connected\"}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Getting in the car")
    }

    @Test func specificLocationSubOrderBytes() throws {
        let loc = SpecificLocation(title: "Home", latitude: 37.33, longitude: -122.03, radius: 100.0, proximity: "enter")
        let p = try buildSupportedFilterPayload(location: loc)
        try assertBytes(p, "{\"location\":{\"location\":{\"title\":\"Home\",\"latitude\":37.33,\"radius\":100.0,\"longitude\":-122.03,\"proximity\":\"enter\"}}}")
        #expect(description(try encodeSupportedFilterPayload(p)) == "Location enter: Home")
    }

    @Test func proximitySynonymsMapped() throws {
        let arriving = SpecificLocation(title: "X", latitude: 1.0, longitude: 2.0, radius: 100.0, proximity: "arriving")
        let p1 = try buildSupportedFilterPayload(location: arriving)
        try assertBytes(p1, "{\"location\":{\"location\":{\"title\":\"X\",\"latitude\":1.0,\"radius\":100.0,\"longitude\":2.0,\"proximity\":\"enter\"}}}")
        let leaving = SpecificLocation(title: "X", latitude: 1.0, longitude: 2.0, radius: 100.0, proximity: "exit")
        let p2 = try buildSupportedFilterPayload(location: leaving)
        try assertBytes(p2, "{\"location\":{\"location\":{\"title\":\"X\",\"latitude\":1.0,\"radius\":100.0,\"longitude\":2.0,\"proximity\":\"leave\"}}}")
    }

    @Test func vehicleAndLocationThrows() {
        let loc = SpecificLocation(title: "X", latitude: 1.0, longitude: 2.0, radius: 100.0, proximity: "enter")
        do {
            _ = try buildSupportedFilterPayload(vehicle: "connected", location: loc)
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Pass either --vehicle or a specific location, not both.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - compound (operation FIRST)

    @Test func compoundOperationFirst() throws {
        let p = try buildSupportedFilterPayload(match: "any", flagged: true, priorities: ["high"])
        try assertBytes(p, "{\"operation\":\"or\",\"flagged\":true,\"priorities\":[\"high\"]}")
        let data = try encodeSupportedFilterPayload(p)
        #expect(kind(data) == "compound")
        #expect(description(data) == "Match any: Flagged reminders; Priority: high")
    }

    @Test func singleFilterMatchAllOmitsOperation() throws {
        // 1 filter + operation "and" → operation key omitted.
        let p = try buildSupportedFilterPayload(match: "all", flagged: true)
        try assertBytes(p, "{\"flagged\":true}")
    }

    @Test func singleFilterMatchAnyEmitsOperation() throws {
        // 1 filter but operation "or" → operation key IS emitted.
        let p = try buildSupportedFilterPayload(match: "any", flagged: true)
        try assertBytes(p, "{\"operation\":\"or\",\"flagged\":true}")
    }

    @Test func badMatchThrows() {
        do {
            _ = try buildSupportedFilterPayload(match: "either", flagged: true)
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Smart list match must be all or any.")
        } catch { Issue.record("wrong error") }
    }

    @Test func noFiltersThrows() {
        do {
            _ = try buildSupportedFilterPayload()
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Pass at least one smart list filter.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - normalize_filter_date try-order

    @Test func normalizeFilterDateTryOrder() throws {
        // %Y-%m-%d
        #expect(try normalizeFilterDate("2026-04-03") == "03-04-2026")
        // %d-%m-%Y (03-04-2026 is DD-MM, NOT matched as %Y-%m-%d since 03 != 4-digit year)
        #expect(try normalizeFilterDate("03-04-2026") == "03-04-2026")
        // %d/%m/%Y
        #expect(try normalizeFilterDate("03/04/2026") == "03-04-2026")
        // %Y/%m/%d
        #expect(try normalizeFilterDate("2026/04/03") == "03-04-2026")
        // non-padded components accepted (Python strptime)
        #expect(try normalizeFilterDate("1-2-2026") == "01-02-2026")
        #expect(try normalizeFilterDate("2026-1-2") == "02-01-2026")
        // leap year valid / invalid
        #expect(try normalizeFilterDate("2024-02-29") == "29-02-2024")
    }

    @Test func normalizeFilterDateRejectsInvalidCalendarDates() {
        for bad in ["2026-13-01", "2026-02-29", "13-13-2026", "31-04-2026", "2026-00-01", "00-01-2026"] {
            #expect(throws: SmartListFilterError.self) { _ = try normalizeFilterDate(bad) }
        }
    }

    @Test func normalizeFilterDateEmptyThrows() {
        do {
            _ = try normalizeFilterDate("   ")
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Smart list date cannot be empty.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - encode rejection (summary nil / unsupported / kind=="all")

    @Test func encodeRejectsEmptyAll() {
        do {
            _ = try encodeSupportedFilterPayload(JSONValue.object([]))
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Unsupported smart list filter shape.")
        } catch { Issue.record("wrong error") }
    }

    @Test func encodeRejectsUnsupportedShape() {
        // legacy hashtags-array form summarizes as unsupported.
        let payload = JSONValue.object([("hashtags", .object([("hashtags", .array([.string("x")]))]))])
        do {
            _ = try encodeSupportedFilterPayload(payload)
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Unsupported smart list filter shape.")
        } catch { Issue.record("wrong error") }
    }

    // MARK: - --filter-json verbatim (inline + @path) + re-rejection

    @Test func filterJSONInlineVerbatim() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        var args = SmartListFilterArgs()
        args.filterJSON = "{\"operation\":\"and\",\"flagged\":true,\"priorities\":[\"high\"]}"
        let data = try encodeSupportedFilterPayload(args, store: s)
        // verbatim — order preserved exactly as supplied.
        #expect(String(data: data, encoding: .utf8) == "{\"operation\":\"and\",\"flagged\":true,\"priorities\":[\"high\"]}")
    }

    @Test func filterJSONAtPathVerbatim() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("filter.json")
        try "{\"flagged\":true}".write(to: file, atomically: true, encoding: .utf8)
        var args = SmartListFilterArgs()
        args.filterJSON = "@" + file.path
        let data = try encodeSupportedFilterPayload(args, store: s)
        #expect(String(data: data, encoding: .utf8) == "{\"flagged\":true}")
    }

    @Test func filterJSONStillRejectedIfUnsupported() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        var args = SmartListFilterArgs()
        args.filterJSON = "{}"  // kind == all → rejected even via filter-json
        do {
            _ = try encodeSupportedFilterPayload(args, store: s)
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Unsupported smart list filter shape.")
        } catch { Issue.record("wrong error") }
    }

    @Test func filterJSONNonObjectThrows() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        var args = SmartListFilterArgs()
        args.filterJSON = "[1,2,3]"
        do {
            _ = try encodeSupportedFilterPayload(args, store: s)
            Issue.record("expected throw")
        } catch let e as SmartListFilterError {
            #expect(e.message == "Smart list filter JSON must be an object.")
        } catch { Issue.record("wrong error") }
    }

    @Test func filterJSONBadPathThrows() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        var args = SmartListFilterArgs()
        args.filterJSON = "@/nonexistent/path/filter.json"
        #expect(throws: SmartListFilterError.self) {
            _ = try encodeSupportedFilterPayload(args, store: s)
        }
    }

    // MARK: - list resolution via fixture store (names + ids → objectUUID)

    @Test func listResolutionByNameAndId() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        // Resolver maps ids first (by Z_PK), then names — each → objectUUID.
        let uuids = try resolveSmartListFilterListIds(store: s, names: ["Home"], ids: [10])
        #expect(uuids == ["UUID-A", "UUID-B"])  // id 10 (Work=UUID-A) before name Home=UUID-B
        // Two included → "or" emitted (guard would reject 2 includes, so build directly).
        let p = try buildSupportedFilterPayload(includeUUIDs: uuids)
        let data = try encodeSupportedFilterPayload(p)
        #expect(String(data: data, encoding: .utf8) == "{\"lists\":{\"include\":[\"UUID-A\",\"UUID-B\"],\"exclude\":[],\"operation\":\"or\"}}")
    }

    @Test func listResolutionByNameSingle() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        var args = SmartListFilterArgs()
        args.includeList = ["Work"]
        let data = try encodeSupportedFilterPayload(args, store: s)
        #expect(String(data: data, encoding: .utf8) == "{\"lists\":{\"include\":[\"UUID-A\"],\"exclude\":[]}}")
    }

    @Test func listResolutionNoUUIDThrows() throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        // NoCK (pk 12) has NULL ckid → "has no object UUID."
        #expect(throws: SmartListFilterError.self) {
            _ = try resolveSmartListFilterListIds(store: s, names: ["NoCK"], ids: [])
        }
    }

    // MARK: - validate_materializing_smart_list_args messages

    @Test func materializeGuardSkippedWithFilterJSON() throws {
        var args = SmartListFilterArgs()
        args.filterJSON = "{\"flagged\":true}"
        args.untagged = true  // would normally throw, but filter-json skips the guard
        try validateMaterializingSmartListArgs(args)  // no throw
    }

    @Test func materializeGuardUntagged() {
        var args = SmartListFilterArgs(); args.untagged = true
        expectGuard(args, "Untagged smart-list writes do not materialize reliably in Reminders.app.")
    }

    @Test func materializeGuardNoDate() {
        var args = SmartListFilterArgs(); args.date = "no-date"
        expectGuard(args, "No-date smart-list writes do not materialize reliably in Reminders.app.")
    }

    @Test func materializeGuardRelative() {
        var args = SmartListFilterArgs(); args.dateRelative = "in-next:3:days"
        expectGuard(args, "Relative-date smart-list writes do not materialize reliably in Reminders.app.")
    }

    @Test func materializeGuardNoTime() {
        var args = SmartListFilterArgs(); args.time = "no-time"
        expectGuard(args, "No-time smart-list writes do not materialize reliably in Reminders.app.")
    }

    @Test func materializeGuardVehicleDisconnected() {
        var args = SmartListFilterArgs(); args.vehicle = "disconnected"
        expectGuard(args, "Vehicle-disconnected smart-list writes do not materialize reliably in Reminders.app.")
    }

    @Test func materializeGuardExclude() {
        var args = SmartListFilterArgs(); args.excludeList = ["Home"]
        expectGuard(args, "List exclusion filters do not materialize reliably in Reminders.app.")
    }

    @Test func materializeGuardIncludeMoreThanOne() {
        var args = SmartListFilterArgs(); args.includeList = ["Work,Home"]  // CSV → 2 names
        expectGuard(args, "Reminders.app only materializes one included-list filter at a time.")
    }

    @Test func materializeGuardIncludeWithListMatch() {
        var args = SmartListFilterArgs(); args.includeList = ["Work"]; args.listMatch = "any"
        expectGuard(args, "Do not pass --list-match with a single included list.")
    }

    @Test func materializeGuardAllowsValidSingleInclude() throws {
        var args = SmartListFilterArgs(); args.includeListId = [10]
        try validateMaterializingSmartListArgs(args)  // no throw
    }

    private func expectGuard(_ args: SmartListFilterArgs, _ message: String) {
        do {
            try validateMaterializingSmartListArgs(args)
            Issue.record("expected throw for: \(message)")
        } catch let e as SmartListFilterError {
            #expect(e.message == message)
        } catch { Issue.record("wrong error type") }
    }

    // MARK: - smart_list_filter_changes_from_args

    @Test func changesFromArgsDetectsEachField() {
        #expect(smartListFilterChangesFromArgs(SmartListFilterArgs()) == false)
        var a = SmartListFilterArgs(); a.filterJSON = "{}"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.flagged = true; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.anyTag = true; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.untagged = true; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.dateTodayIncludePastDue = true; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.priority = "high"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.tags = "work"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.date = "today"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.dateOn = "2026-01-01"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.dateRange = "a,b"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.dateRelative = "in-next:1:day"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.time = "morning"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.includeList = ["Work"]; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.excludeListId = [11]; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.vehicle = "connected"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.locationTitle = "Home"; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.latitude = 1.0; #expect(smartListFilterChangesFromArgs(a))
        a = SmartListFilterArgs(); a.longitude = 1.0; #expect(smartListFilterChangesFromArgs(a))
    }

    @Test func changesFromArgsEmptyStringsAreNoChange() {
        var a = SmartListFilterArgs()
        a.priority = ""
        a.tags = ""
        a.date = ""
        a.vehicle = ""
        a.locationTitle = ""
        a.filterJSON = ""
        #expect(smartListFilterChangesFromArgs(a) == false)
    }
}
