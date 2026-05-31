import ArgumentParser
import Foundation

let smartListCommands: [ParsableCommand.Type] = [
    SmartLists.self, SmartListCreate.self, SmartListEdit.self, SmartListDelete.self,
]

struct SmartLists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-lists", abstract: "List smart lists.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead { store in
            let payloads = store.smartLists().map { smartListToDict($0) }
            if opts.json {
                Dispatch.printJSON(.array(payloads.map { .object($0) }), ensureAscii: false)
                return
            }
            let ansi = opts.ansi()
            if payloads.isEmpty { print("No smart lists"); return }
            print(ansi.bold("Smart Lists:"))
            for item in payloads {
                let d = Dictionary(item, uniquingKeysWith: { a, _ in a })
                func str(_ k: String) -> String? { if case let .string(v)? = d[k] { return v }; return nil }
                func intOf(_ k: String) -> Int { if case let .int(v)? = d[k] { return v }; return 0 }
                let kind = str("kind") ?? "built-in"
                let smartType = str("smartListType") ?? "(none)"
                let length = intOf("filterLength")
                let isPinned: Bool = { if case let .bool(v)? = d["pinned"] { return v }; return false }()
                // filter summary description
                var desc = "No filter data"
                var supported = true
                var keys: [String] = []
                if case let .object(summary)? = d["filter"] {
                    let sd = Dictionary(summary, uniquingKeysWith: { a, _ in a })
                    if case let .string(v)? = sd["description"], !v.isEmpty { desc = v }
                    if case let .bool(s)? = sd["supported"] { supported = s }
                    if case let .array(ks)? = sd["keys"] { keys = ks.compactMap { if case let .string(s) = $0 { return s } else { return nil } } }
                }
                var line = safeDisplay(desc)
                if d["filter"] != nil, !supported {
                    let keyStr = keys.isEmpty ? "unknown keys" : keys.joined(separator: ", ")
                    line = "\(line): \(safeDisplay(keyStr))"
                }
                let pinInfo = isPinned ? ansi.dim(" [pinned]") : ""
                print("  \(safeDisplay(str("name"))) \(ansi.dim("(id: \(intOf("id")), \(kind))"))\(pinInfo)")
                print("    \(smartType) · filter bytes: \(length) · \(line)")
            }
            let n = payloads.count
            print("\n\(n) smart list\(n == 1 ? "" : "s")")
        }
    }
}

/// Shared `--filter-*` flag surface for smart-list-create / smart-list-edit. Mirrors
/// `add_smart_list_filter_arguments` (remctl:6379). SUPPRESS/hidden flags from the Python parser
/// (`--untagged`, `--date-relative`, `--exclude-list`, `--exclude-list-id`, `--list-match`) are
/// declared `.hidden` so they keep functioning for parity but stay out of `--help`.
struct SmartListFilterOptions: ParsableArguments {
    @Option(name: .long, help: "Match all or any supplied filters") var match: String = "all"
    @Option(name: .customLong("filter-json"), help: "Advanced: raw official smart-list filter JSON or @path") var filterJson: String?
    @Flag(name: .long, help: "Filter to flagged reminders") var flagged = false
    @Option(name: .long, help: "Priority filter: high, medium, low, or comma-separated values") var priority: String?
    @Option(name: .long, help: "Selected tag filter, comma-separated; # prefix optional") var tags: String?
    @Option(name: .customLong("tag-match"), help: "Selected tag matching mode") var tagMatch: String = "any"
    @Flag(name: .customLong("any-tag"), help: "Filter to reminders with any tag") var anyTag = false
    @Flag(name: .long, help: .hidden) var untagged = false
    @Option(name: .long, help: "Date filter") var date: String?
    @Flag(name: .customLong("date-today-include-past-due"), help: "Include past due reminders with --date today") var dateTodayIncludePastDue = false
    @Option(name: .customLong("date-on"), help: "Date filter: on YYYY-MM-DD") var dateOn: String?
    @Option(name: .customLong("date-before"), help: "Date filter: before YYYY-MM-DD") var dateBefore: String?
    @Option(name: .customLong("date-after"), help: "Date filter: after YYYY-MM-DD") var dateAfter: String?
    @Option(name: .customLong("date-range"), help: "Date filter range: START,END") var dateRange: String?
    @Option(name: .customLong("date-relative"), help: .hidden) var dateRelative: String?
    @Option(name: .long, help: "Time-of-day filter") var time: String?
    @Option(name: .customLong("include-list"), parsing: .singleValue, help: "Include reminders from one list name") var includeList: [String] = []
    @Option(name: .customLong("exclude-list"), parsing: .singleValue, help: .hidden) var excludeList: [String] = []
    @Option(name: .customLong("include-list-id"), parsing: .singleValue, help: "Include reminders from one numeric list ID") var includeListId: [Int] = []
    @Option(name: .customLong("exclude-list-id"), parsing: .singleValue, help: .hidden) var excludeListId: [Int] = []
    @Option(name: .customLong("list-match"), help: .hidden) var listMatch: String?
    @Option(name: .long, help: "Location vehicle filter") var vehicle: String?
    @Option(name: .customLong("location-title"), help: "Specific location title") var locationTitle: String?
    @Option(name: .long, help: "Specific location latitude") var latitude: Double?
    @Option(name: .long, help: "Specific location longitude") var longitude: Double?
    @Option(name: .long, help: "Specific location radius in meters") var radius: Double = 100.0
    @Option(name: .long, help: "Specific location proximity") var proximity: String = "enter"

    /// Bundle the parsed flags into the P15 `SmartListFilterArgs` struct.
    func toFilterArgs() -> SmartListFilterArgs {
        SmartListFilterArgs(
            match: match, filterJSON: filterJson, flagged: flagged, priority: priority,
            tags: tags, tagMatch: tagMatch, anyTag: anyTag, untagged: untagged,
            date: date, dateTodayIncludePastDue: dateTodayIncludePastDue,
            dateOn: dateOn, dateBefore: dateBefore, dateAfter: dateAfter,
            dateRange: dateRange, dateRelative: dateRelative, time: time,
            includeList: includeList, excludeList: excludeList,
            includeListId: includeListId, excludeListId: excludeListId,
            listMatch: listMatch, vehicle: vehicle, locationTitle: locationTitle,
            latitude: latitude, longitude: longitude, radius: radius, proximity: proximity)
    }
}

/// Build the `private` JSON sub-object the same way as list-edit/list-pin: `status` first, then
/// the helper's echoed fields sorted by key for stable output.
private func privateSubObject(_ result: PrivateResult) -> JSONValue {
    var pairs: [(String, JSONValue)] = [("status", .string(result.status))]
    for key in result.fields.keys.sorted() { pairs.append((key, result.fields[key]!)) }
    return .object(pairs)
}

/// The decoded `summary` of just-encoded filter bytes (`decode_smart_list_filter_blob(...)["summary"]`),
/// as the JSON `filter` field (object) — or `.null` when there is no summary.
private func filterSummaryJSON(_ filterData: Data) -> JSONValue {
    if let summary = decodeSmartListFilterBlob(filterData).summary { return .object(summary) }
    return .null
}

/// The `summary["description"]` string for the human `Filter:` line, or nil when absent/empty.
private func filterSummaryDescription(_ filterData: Data) -> String? {
    guard let summary = decodeSmartListFilterBlob(filterData).summary else { return nil }
    if case let .string(desc)? = summary.first(where: { $0.0 == "description" })?.1, !desc.isEmpty { return desc }
    return nil
}

struct SmartListCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-create", abstract: "Create a smart list.")

    @Argument(help: "Smart list name") var name: String
    @Option(name: .long, help: "Smart-list color name or #RRGGBB") var color: String?
    @Option(name: .long, help: "Official Reminders list symbol name") var symbol: String?
    @Option(name: .long, help: "Emoji badge") var emoji: String?
    @OptionGroup var filter: SmartListFilterOptions
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, color: args.color, symbol: args.symbol, emoji: args.emoji,
                filterArgs: args.filter.toFilterArgs(), json: args.json, store: store, private: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_smart_list_create` (remctl:4559).
    /// PHASE-3 DIVERGENCE: the `if not private_metadata_enabled: requires --private.` gate is
    /// DROPPED (private capability is unconditional). The create path ALWAYS encodes a filter.
    static func perform(
        name: String, color: String?, symbol: String?, emoji: String?,
        filterArgs: SmartListFilterArgs, json: Bool,
        store: RemindersStore, private priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // 1. Duplicate-name preflight (exact, case-sensitive). Fires before validation/encoding.
        if store.customSmartListExactNameCount(name: name) > 0 {
            return .error("smart list already exists: \(name). Choose a unique test name.")
        }
        // 2. Appearance validation (symbol XOR emoji, unknown symbol, bad color, ...).
        try validateListAppearanceArgs(
            color: color, symbol: symbol, emoji: emoji,
            groceries: false, standard: false, groceryLocale: nil)

        // 3. Build + encode the filter payload (P15). materializing-validation is performed inside
        //    smartListFilterPayloadFromArgs (skipped when --filter-json given). SmartListFilterError
        //    propagates out → mapped to "Error: <msg>" by WriteDispatch.perform.
        let filterData = try encodeSupportedFilterPayload(filterArgs, store: store)

        // 4. Build the appearance payload.
        let appearance = buildListAppearance(
            newName: nil, color: color, symbol: symbol, emoji: emoji,
            groceries: false, standard: false, groceryLocale: nil)

        // 5. Invoke the private writer.
        let result: PrivateResult
        do {
            result = try await priv.createSmartList(name: name, filterData: filterData, appearance: appearance)
        } catch let e as WriteError {
            return .error("Failed to create smart list '\(name)': \(e.message.isEmpty ? "private helper failed" : e.message)")
        } catch {
            return .error("Failed to create smart list '\(name)': \(error)")
        }
        guard result.status == "created" else {
            return .error("Failed to create smart list '\(name)': \(result.message ?? "private helper failed")")
        }

        // 6. Output.
        if json {
            let obj: JSONValue = .object([
                ("status", .string("created")),
                ("name", .string(name)),
                ("filter", filterSummaryJSON(filterData)),
                ("private", privateSubObject(result)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        var out = "Created smart list: \(safeDisplay(name))\n"
        if let desc = filterSummaryDescription(filterData) {
            out += "Filter: \(safeDisplay(desc))\n"
        }
        return .ok(out)
    }
}

struct SmartListEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-edit", abstract: "Edit a smart list.")

    @Argument(help: "Smart list name to edit") var name: String?
    @Option(name: .customLong("smart-list-id"), help: "Edit a smart list by stable numeric ID") var smartListId: Int?
    @Option(name: .long, help: "Smart-list color name or #RRGGBB") var color: String?
    @Option(name: .long, help: "Official Reminders list symbol name") var symbol: String?
    @Option(name: .long, help: "Emoji badge") var emoji: String?
    @OptionGroup var filter: SmartListFilterOptions
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, smartListId: args.smartListId,
                color: args.color, symbol: args.symbol, emoji: args.emoji,
                filterArgs: args.filter.toFilterArgs(), json: args.json, store: store, private: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_smart_list_edit` (remctl:4604).
    /// PHASE-3 DIVERGENCE: the `requires --private.` gate is DROPPED. `filterData` is OMITTED
    /// (nil) from updateSmartList when only appearance changed — preserving the existing filter.
    static func perform(
        name: String?, smartListId: Int?,
        color: String?, symbol: String?, emoji: String?,
        filterArgs: SmartListFilterArgs, json: Bool,
        store: RemindersStore, private priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // 1. Require a target selector.
        let hasName = name != nil && !(name!.isEmpty)
        if !hasName && smartListId == nil {
            return .error("provide a smart list name or --smart-list-id.")
        }
        // 2. Appearance validation (no-op when none supplied).
        try validateListAppearanceArgs(
            color: color, symbol: symbol, emoji: emoji,
            groceries: false, standard: false, groceryLocale: nil)

        // 3. Resolve target (custom smart lists only, EXACT-name or Z_PK).
        let target = try resolveCustomSmartList(store: store, name: name, smartListId: smartListId)

        // 4. Change-detection: at least one filter or appearance change required.
        let hasFilterChanges = smartListFilterChangesFromArgs(filterArgs)
        let hasAppearanceChanges = (color != nil && !color!.isEmpty)
            || (symbol != nil && !symbol!.isEmpty) || (emoji != nil && !emoji!.isEmpty)
        if !hasFilterChanges && !hasAppearanceChanges {
            return .error("pass at least one smart-list filter or appearance option.")
        }

        // 5. Encode filter ONLY when a filter change was requested; otherwise omit (nil) to preserve.
        var filterData: Data?
        if hasFilterChanges {
            filterData = try encodeSupportedFilterPayload(filterArgs, store: store)
        }

        // 6. Require a stable CloudKit identifier.
        guard let ckid = target.ckid, !ckid.isEmpty else {
            return .error("target smart list has no stable CloudKit identifier.")
        }

        let appearance = buildListAppearance(
            newName: nil, color: color, symbol: symbol, emoji: emoji,
            groceries: false, standard: false, groceryLocale: nil)

        // 7. Invoke the private writer.
        let result: PrivateResult
        do {
            result = try await priv.updateSmartList(smartListId: ckid, filterData: filterData, appearance: appearance)
        } catch let e as WriteError {
            return .error("Failed to edit smart list '\(target.name)': \(e.message.isEmpty ? "private helper failed" : e.message)")
        } catch {
            return .error("Failed to edit smart list '\(target.name)': \(error)")
        }
        guard result.status == "updated" else {
            return .error("Failed to edit smart list '\(target.name)': \(result.message ?? "private helper failed")")
        }

        // 8. Output.
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("updated")),
                ("id", .int(target.pk)),
                ("objectUUID", .string(ckid)),
                ("name", .string(target.name)),
            ]
            if let filterData { pairs.append(("filter", filterSummaryJSON(filterData))) }
            pairs.append(("private", privateSubObject(result)))
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n")
        }
        var out = "Updated smart list: \(safeDisplay(target.name))\n"
        if let filterData, let desc = filterSummaryDescription(filterData) {
            out += "Filter: \(safeDisplay(desc))\n"
        }
        return .ok(out)
    }
}

/// A resolved custom-smart-list target (Z_PK / display name / CloudKit identifier).
struct CustomSmartListTarget {
    var pk: Int
    var name: String
    var ckid: String?
}

/// Shared resolution for smart-list edit/delete: EXACT-name match (ORDER BY Z_PK) or `--smart-list-id`.
/// Throws WriteError on not-found / ambiguous, matching `cmd_smart_list_edit/delete` (remctl:4614).
/// Callers guard the no-selector case before calling.
func resolveCustomSmartList(store: RemindersStore, name: String?, smartListId: Int?) throws -> CustomSmartListTarget {
    let matches: [(pk: Int, name: String, ckid: String?)] =
        smartListId != nil ? store.customSmartListMatches(smartListId: smartListId!)
                           : store.customSmartListMatches(name: name ?? "")
    if matches.isEmpty {
        let targetDesc = smartListId != nil ? "id \(smartListId!)" : (name ?? "")
        throw WriteError("custom smart list not found: \(targetDesc)")
    }
    if matches.count > 1 {
        var msg = "multiple custom smart lists match. Use --smart-list-id."
        for row in matches { msg += "\n  \(row.pk): \(row.name)" }
        throw WriteError(msg)
    }
    let row = matches[0]
    return CustomSmartListTarget(pk: row.pk, name: row.name, ckid: row.ckid)
}

struct SmartListDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-delete", abstract: "Delete a smart list.")

    @Argument(help: "Smart list name to delete") var name: String?
    @Option(name: .customLong("smart-list-id"), help: "Delete a smart list by stable numeric ID") var smartListId: Int?
    @Flag(name: .long, help: "Skip the confirmation prompt") var force = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, smartListId: args.smartListId, force: args.force, json: args.json,
                store: store, private: priv, confirm: { prompt in
                    FileHandle.standardOutput.write(Data(prompt.utf8))
                    let line = readLine() ?? ""
                    return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
                })
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_smart_list_delete` (remctl:4668). `confirm`
    /// receives the full prompt string and returns the user's yes/no (only "y"/"yes" accept).
    /// PHASE-3 DIVERGENCE: the `requires --private.` gate is DROPPED.
    static func perform(
        name: String?, smartListId: Int?, force: Bool, json: Bool,
        store: RemindersStore, private priv: PrivateWriter, confirm: (_ prompt: String) -> Bool
    ) async throws -> WriteOutcome {
        // 1. Require a target selector.
        let hasName = name != nil && !(name!.isEmpty)
        if !hasName && smartListId == nil {
            return .error("provide a smart list name or --smart-list-id.")
        }
        // 2. Resolve (custom-only, EXACT-name or Z_PK). Not-found/ambiguous propagate as WriteError.
        let target = try resolveCustomSmartList(store: store, name: name, smartListId: smartListId)

        // 3. Confirmation unless --force. A non-yes answer prints "Aborted." and returns exit 0
        //    with NO JSON, even in --json mode.
        if !force {
            let prompt = "Delete custom smart list '\(safeDisplay(target.name))'? [y/N] "
            guard confirm(prompt) else { return .ok("Aborted.\n") }
        }

        // 4. Require a stable CloudKit identifier.
        guard let ckid = target.ckid, !ckid.isEmpty else {
            return .error("target smart list has no stable CloudKit identifier.")
        }

        // 5. Invoke the private writer.
        let result: PrivateResult
        do {
            result = try await priv.deleteSmartList(smartListId: ckid)
        } catch let e as WriteError {
            return .error("Failed to delete smart list '\(target.name)': \(e.message.isEmpty ? "private helper failed" : e.message)")
        } catch {
            return .error("Failed to delete smart list '\(target.name)': \(error)")
        }
        guard result.status == "deleted" else {
            return .error("Failed to delete smart list '\(target.name)': \(result.message ?? "private helper failed")")
        }

        // 6. Output.
        if json {
            let obj: JSONValue = .object([
                ("status", .string("deleted")),
                ("id", .int(target.pk)),
                ("objectUUID", .string(ckid)),
                ("name", .string(target.name)),
                ("private", privateSubObject(result)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        return .ok("Deleted smart list: \(safeDisplay(target.name))\n")
    }
}
