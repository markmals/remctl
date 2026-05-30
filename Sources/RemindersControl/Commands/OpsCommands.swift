import ArgumentParser
import Foundation
import GRDB

enum ExportFormat: String, ExpressibleByArgument, CaseIterable { case json, csv }

let opsCommands: [ParsableCommand.Type] = [
    Export.self, Import.self, CompletionCmd.self, Doctor.self, Onboard.self, Permissions.self, Setup.self,
]

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export reminders.")
    @Option(name: [.short, .long], help: "Export only this list (by name)") var list: String?
    @Option(name: .long, help: "Export only this list (by numeric ID)") var listId: Int?
    @Option(name: .long, help: "Output format") var format: ExportFormat = .json
    @Flag(name: .long, help: "Accepted for compatibility; output is governed by --format") var json = false

    func run() throws {
        Dispatch.runRead { store in
            let items: [Row]
            if list != nil || listId != nil {
                let pk = try resolveRequiredListTarget(store: store, name: list, listId: listId).id
                items = store.reminders(listPk: pk, completed: true, topLevel: false, limit: 10000)
            } else {
                items = store.reminders(completed: true, topLevel: false, limit: 10000)
            }
            let objs = serializeReminders(items, store: store)

            switch format {
            case .json:
                Dispatch.printJSON(.array(objs.map { .object($0) }), ensureAscii: true)
            case .csv:
                var rows: [[String]] = [["id", "title", "list", "completed", "flagged", "urgent",
                                         "priority", "due_date", "notes", "url", "tags"]]
                for obj in objs {
                    let d = Dictionary(obj, uniquingKeysWith: { a, _ in a })
                    func str(_ k: String) -> String { if case let .string(v)? = d[k] { return v }; return "" }
                    func intStr(_ k: String) -> String { if case let .int(v)? = d[k] { return String(v) }; return "" }
                    func boolStr(_ k: String) -> String { if case let .bool(v)? = d[k] { return v ? "True" : "False" }; return "False" }
                    var tags = ""
                    if case let .array(arr)? = d["tags"] {
                        tags = arr.compactMap { if case let .string(t) = $0 { return t } else { return nil } }.joined(separator: ",")
                    }
                    rows.append([intStr("id"), str("title"), str("list"), boolStr("completed"),
                                 boolStr("flagged"), boolStr("urgent"), str("priority"),
                                 str("dueDate"), str("notes"), str("url"), tags])
                }
                print(CSV.writeRows(rows), terminator: "")
            }
        }
    }
}

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import reminders.")

    @Argument(help: "Path to a JSON file containing an array of reminder objects") var file: String
    @Flag(name: .long, help: "Emit the created/errors/total summary as one-line JSON instead of text.") var json = false

    func run() async throws {
        let path = file, json = self.json
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            await Self.perform(
                path: path,
                readFile: { p in
                    let url = URL(fileURLWithPath: p)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return try? Data(contentsOf: url)
                },
                json: json, store: store, writer: writer)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_import`: replays each JSON item through
    /// `Add.perform` (the `add` code path), accumulating created/errors counts. `readFile`
    /// is injected so tests can supply canned bytes (or nil for "not found") without touching
    /// the real filesystem; `now`/`calendar` flow into per-item due parsing.
    ///
    /// Divergences from Python (documented for parity reviewers):
    ///   1. JSON decode error: Python interpolates the `json.JSONDecodeError`/`IOError` text;
    ///      Swift's decoder text differs, so only the `Failed to read JSON: ` prefix matches.
    ///   2. Non-object array elements: Python would crash on `item.get(...)` for a non-dict;
    ///      this port treats them as title-less (Warning + errors += 1) rather than crashing.
    ///   3. `flagged: true` items: Add's `--flag` is a stubbed Phase-3 flag, so such items make
    ///      `Add.perform` return a Phase-3 error (exit 1) and are counted as `errors` — import
    ///      faithfully inherits add's stubs.
    static func perform(
        path: String,
        readFile: (String) -> Data?,
        json: Bool, store: RemindersStore, writer: RemindersWriter,
        now: Date = Date(), calendar: Calendar = .current
    ) async -> WriteOutcome {

        // Top-level error paths (each exit 1, NO per-item processing).
        guard let data = readFile(path) else {
            return .error("File '\(path)' not found")
        }
        guard let decoded = decodeJSON(data) else {
            return .error("Failed to read JSON: \(jsonErrorText(data))")
        }
        guard case let .array(items) = decoded else {
            return .error("JSON must be an array of reminder objects")
        }

        let total = items.count
        var created = 0
        var errors = 0
        var out = ""
        var err = ""

        for element in items {
            // Non-object elements are treated as title-less (divergence #2).
            guard case let .object(pairs) = element else {
                err += "Warning: Skipping item without title\n"
                errors += 1
                continue
            }
            func field(_ key: String) -> JSONValue? { pairs.first(where: { $0.0 == key })?.1 }
            func str(_ key: String) -> String? { if case let .string(s)? = field(key) { return s }; return nil }

            // title: a non-empty String. Falsy (missing/null/empty/non-string) → skip.
            guard let title = str("title"), !title.isEmpty else {
                err += "Warning: Skipping item without title\n"
                errors += 1
                continue
            }

            // due wins over dueDate when both are present.
            let due = str("due") ?? str("dueDate")

            // priority: string forwarded as-is; int stringified (→ Add's priority parse fails);
            // anything else dropped.
            var priority: String? = nil
            switch field("priority") {
            case let .string(s)?: priority = s
            case let .int(n)?: priority = String(n)
            default: break
            }

            // flagged → Add's --flag (a Phase-3 stub; true makes Add error — divergence #3).
            var flag = false
            if case let .bool(b)? = field("flagged") { flag = b }

            // Replay through the add core with json:false ALWAYS (even when import's --json is set);
            // tags are deliberately dropped (tags: nil). WriteDispatch.perform maps any thrown
            // WriteError/phase3 to a non-zero WriteOutcome so item failures never abort the loop.
            let outcome = await WriteDispatch.perform {
                try await Add.perform(
                    title: title, list: str("list"), notes: str("notes"),
                    due: due, priority: priority,
                    recurrence: str("recurrence"), alarm: str("alarm"),
                    url: str("url"), flag: flag, tags: nil,
                    json: false, store: store, writer: writer, now: now, calendar: calendar)
            }
            out += outcome.stdout
            err += outcome.stderr
            if outcome.exitCode == 0 { created += 1 } else { errors += 1 }
        }

        // Summary. Import ALWAYS exits 0 on the main path (cmd_import has no final sys.exit).
        if json {
            let summary: JSONValue = .object([
                ("created", .int(created)),
                ("errors", .int(errors)),
                ("total", .int(total)),
            ])
            out += summary.serialized(indent: nil, ensureAscii: true) + "\n"
        } else {
            out += "\nImported \(created)/\(total) reminders (\(errors) errors)\n"
        }
        return WriteOutcome(stdout: out, stderr: err, exitCode: 0)
    }

    /// Decode the file bytes to an order-preserving JSONValue (nil on malformed JSON).
    private static func decodeJSON(_ data: Data) -> JSONValue? { OrderedJSON.parse(data) }

    /// Best-effort Swift error text for the `Failed to read JSON:` message. `OrderedJSON.parse`
    /// returns nil without an error object, so we re-run Foundation's decoder to surface a real
    /// thrown error string. Divergence #1: this will NOT match Python's exception text.
    private static func jsonErrorText(_ data: Data) -> String {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return "malformed JSON"  // OrderedJSON rejected what Foundation accepted (e.g. trailing data)
        } catch {
            return "\(error)"
        }
    }
}

// Named `CompletionCmd` (not `Completion`) to stay clear of ArgumentParser's
// completion-script machinery; `commandName` remains "completion".
struct CompletionCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Print a shell completion script.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("completion") }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Diagnose setup and permissions.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("doctor") }
}

struct Onboard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "onboard", abstract: "First-run onboarding.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("onboard") }
}

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Guided Full Disk Access setup.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("permissions") }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Install shell completions/config.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("setup") }
}
