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

    @Argument(help: "Path to a JSON file containing an array of reminder objects, or - for standard input") var file: String
    @Flag(name: .long, help: "Validate every reminder without creating any") var dryRun = false
    @Flag(name: .long, help: "Emit the created/errors/total summary as one-line JSON instead of text.") var json = false

    func run() async throws {
        let path = file, json = self.json, dryRun = self.dryRun
        WriteDispatch.emit(await WriteDispatch.runShellBoth { store, writer, priv in
            await Self.perform(
                path: path,
                readFile: { p in
                    let url = URL(fileURLWithPath: p)
                    // Return nil ONLY when the file does not exist (triggers "not found" error).
                    // When the file exists but is unreadable, return Data() (empty) so the JSON
                    // decode step fails with "Failed to read JSON:" — matching Python's IOError path.
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return (try? Data(contentsOf: url)) ?? Data()
                },
                stdin: .standard,
                json: json, dryRun: dryRun, store: store, writer: writer, private: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_import` (upstream a579db5): the WHOLE document
    /// is validated before the first write, so one bad item can never leave the earlier ones
    /// half-created. Valid items then replay through `Add.perform` (the `add` code path, always in
    /// JSON mode so the created identifier can be captured); a runtime failure mid-import reports
    /// `status: "partial"` with the created ids and indexed errors, and exits 1. A `path` of `-`
    /// takes the document from `stdin` instead, and `dryRun` (upstream 8f15241) stops right after
    /// validation, reporting `status: "valid"` without calling a writer. `readFile`/`stdin` are
    /// injected so tests can supply canned bytes (or nil for "not found") without touching the real
    /// filesystem or the process's input; `now`/`calendar` flow into per-item due parsing.
    ///
    /// Divergences from Python (documented for parity reviewers):
    ///   1. JSON decode error: Python interpolates the `json.JSONDecodeError`/`IOError` text;
    ///      Swift's decoder text differs, so only the `Failed to read JSON: ` prefix matches.
    ///   2. Error messages quote a non-string value (a recurrence object) as compact JSON where
    ///      Python prints a `dict` repr.
    ///   3. `flagged: true` items: `--flag` implies the private path, so the import sets the real
    ///      flag through the private writer after EventKit creates the reminder.
    static func perform(
        path: String,
        readFile: (String) -> Data?,
        stdin: StandardInput,
        json: Bool, dryRun: Bool = false, store: RemindersStore, writer: RemindersWriter, private priv: PrivateWriter,
        now: Date = Date(), calendar: Calendar = .current
    ) async -> WriteOutcome {

        // Top-level error paths (each exit 1, NO per-item processing).
        let data: Data
        if path == "-" {
            switch readPipedDocument(stdin) {
            case let .document(bytes):  data = bytes
            case let .refused(outcome): return outcome
            }
        } else {
            guard let bytes = readFile(path) else { return .error("File '\(path)' not found") }
            data = bytes
        }
        guard let decoded = decodeJSON(data) else {
            return .error("Failed to read JSON: \(jsonErrorText(data))")
        }
        guard case let .array(items) = decoded else {
            return .error("JSON must be an array of reminder objects")
        }

        let total = items.count
        var pending: [ImportItem] = []
        var validationErrors: [(index: Int, message: String)] = []
        for (index, element) in items.enumerated() {
            switch validate(element, now: now, calendar: calendar) {
            case let .valid(item):     pending.append(item)
            case let .invalid(message): validationErrors.append((index, message))
            }
        }
        guard validationErrors.isEmpty else {
            return validationFailure(validationErrors, total: total, json: json)
        }

        // --dry-run stops at the validation gate: the document is sound and nothing was written.
        if dryRun {
            let payload: JSONValue = .object([
                ("status", .string("valid")), ("count", .int(pending.count)), ("created", .int(0)),
            ])
            return .ok(payload.serialized(indent: nil, ensureAscii: true) + "\n")
        }

        var out = "", err = ""
        var created = 0
        var createdIds: [JSONValue] = []
        var errors: [JSONValue] = []

        for (index, item) in pending.enumerated() {
            // Items run with json:true so the created id is machine-readable; the item's own
            // output never reaches the caller — import prints its own progress instead.
            let outcome = await WriteDispatch.perform {
                try await Add.perform(
                    title: item.title, list: item.list, notes: item.notes,
                    due: item.due, priority: item.priority,
                    recurrence: item.recurrence, alarm: item.alarm,
                    url: item.url, flag: item.flag, tags: nil,
                    json: true, store: store, writer: writer, private: priv, now: now, calendar: calendar)
            }
            guard outcome.exitCode == 0,
                  case let .object(pairs)? = OrderedJSON.parse(Data(outcome.stdout.utf8)) else {
                let message = [outcome.stderr, outcome.stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? "add exited \(outcome.exitCode)"
                errors.append(.object([
                    ("index", .int(index)), ("title", .string(item.title)), ("message", .string(message)),
                ]))
                if !json { err += "Error: Failed to import \(safeDisplay(item.title)): \(message)\n" }
                continue
            }
            created += 1
            let identifier = createdIdentifier(pairs)
            if let identifier { createdIds.append(identifier.value) }
            if json {
                // Progress on stderr keeps stdout a single parseable summary line.
                err += "imported index=\(index) id=\(safeDisplay(identifier?.text ?? "unknown").prefix(128))\n"
            } else {
                out += "Created: \(safeDisplay(item.title))\n"
            }

        }

        if json {
            let summary: JSONValue = .object([
                ("status", .string(errors.isEmpty ? "completed" : "partial")),
                ("created", .int(created)),
                ("createdIds", .array(createdIds)),
                ("errors", .array(errors)),
                ("total", .int(total)),
            ])
            out += summary.serialized(indent: nil, ensureAscii: true) + "\n"
        } else {
            out += "\nImported \(created)/\(total) reminders (\(errors.count) errors)\n"
        }
        return WriteOutcome(stdout: out, stderr: err, exitCode: errors.isEmpty ? 0 : 1)
    }

    /// One validated row of the import document, normalized into `Add.perform` arguments.
    private struct ImportItem {
        var title: String
        var list: String?
        var notes: String?
        var due: String?
        var priority: String?
        var url: String?
        var recurrence: String?
        var alarm: String?
        var flag: Bool
    }

    private enum ItemValidation {
        case valid(ImportItem)
        case invalid(String)
    }

    /// Validate one array element against the same rules `add` applies, without writing anything.
    private static func validate(_ element: JSONValue, now: Date, calendar: Calendar) -> ItemValidation {
        guard case let .object(pairs) = element else { return .invalid("item must be an object") }
        func field(_ key: String) -> JSONValue? { pairs.first(where: { $0.0 == key })?.1 }
        func str(_ key: String) -> String? { if case let .string(s)? = field(key) { return s }; return nil }

        guard let title = str("title"), !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .invalid("item requires a non-empty string title")
        }
        for key in ["list", "notes", "due", "dueDate", "priority", "url", "alarm"] {
            guard let value = field(key), value != .null else { continue }
            guard case .string = value else { return .invalid("\(key) must be a string") }
        }

        // `due` wins over `dueDate`; an empty string falls through to the other key.
        let due = [str("due"), str("dueDate")].compactMap { $0 }.first(where: { !$0.isEmpty })
        if let due, WriteParsing.parseDue(due, now: now, calendar: calendar) == nil {
            return .invalid("could not parse due date \(WriteFormatting.pyRepr(due))")
        }

        // A string spec OR an exported recurrence object; objects travel on as JSON text, which
        // `Add.perform` re-parses through the same normalizer.
        var recurrence: String? = nil
        if let value = field("recurrence"), value != .null {
            guard WriteParsing.parseRecurrence(value, calendar: calendar) != nil else {
                return .invalid("could not parse recurrence \(valueRepr(value))")
            }
            recurrence = recurrenceSpecText(value)
        }

        if let alarm = str("alarm"), !alarm.isEmpty,
           WriteParsing.parseAlarmSpec(alarm, allowClear: false, calendar: calendar) == nil {
            return .invalid("could not parse alarm \(WriteFormatting.pyRepr(alarm))")
        }
        if let priority = str("priority"), !priority.isEmpty,
           WriteParsing.parsePriority(priority, allowAliases: true) == nil {
            return .invalid("priority must be high, medium, low, or none")
        }
        var flag = false
        if let flagged = field("flagged") {
            guard case let .bool(value) = flagged else { return .invalid("flagged must be a boolean") }
            flag = value
        }

        return .valid(ImportItem(
            title: title, list: str("list"), notes: str("notes"), due: due,
            priority: str("priority"), url: str("url"), recurrence: recurrence,
            alarm: str("alarm"), flag: flag))
    }

    /// Nothing has been written: report every bad item at once and refuse the whole document.
    private static func validationFailure(
        _ errors: [(index: Int, message: String)], total: Int, json: Bool
    ) -> WriteOutcome {
        let message = "Import validation failed; no reminders were created."
        if json {
            let payload: JSONValue = .object([
                ("status", .string("error")),
                ("code", .string("invalid_import")),
                ("message", .string(message)),
                ("created", .int(0)),
                ("createdIds", .array([])),
                ("errors", .array(errors.map {
                    .object([("index", .int($0.index)), ("message", .string($0.message))])
                })),
                ("total", .int(total)),
            ])
            return WriteOutcome(stderr: payload.serialized(indent: nil, ensureAscii: true) + "\n", exitCode: 1)
        }
        var text = "Error: \(message)\n"
        for error in errors { text += "  Item \(error.index): \(error.message)\n" }
        return WriteOutcome(stderr: text, exitCode: 1)
    }

    /// The created reminder's identifier from an `add --json` payload: the numeric id once the row
    /// is visible in the read store, else the EventKit identifier.
    private static func createdIdentifier(_ pairs: [(String, JSONValue)]) -> (value: JSONValue, text: String)? {
        func field(_ key: String) -> JSONValue? { pairs.first(where: { $0.0 == key })?.1 }
        if case let .int(numericId)? = field("numericId"), numericId != 0 {
            return (.int(numericId), String(numericId))
        }
        if case let .string(id)? = field("id"), !id.isEmpty { return (.string(id), id) }
        return nil
    }

    /// Recurrence as `Add.perform` takes it: the original string, or the object's JSON text.
    private static func recurrenceSpecText(_ value: JSONValue) -> String {
        if case let .string(spec) = value { return spec }
        return value.serialized(indent: nil, ensureAscii: true)
    }

    /// Quote a rejected value for an error message (divergence #2).
    private static func valueRepr(_ value: JSONValue) -> String {
        if case let .string(text) = value { return WriteFormatting.pyRepr(text) }
        return value.serialized(indent: nil, ensureAscii: true)
    }

    /// Decode the file bytes to an order-preserving JSONValue (nil on malformed JSON).
    private static func decodeJSON(_ data: Data) -> JSONValue? { OrderedJSON.parse(data) }

    /// The largest document `import -` accepts (Python's 8 MiB cap).
    private static let maxPipedDocumentBytes = 8 * 1024 * 1024

    /// Read the document from standard input (`import -`). A terminal is refused without being
    /// read, so an interactive caller is never left waiting for input nobody is going to type.
    /// Both refusals keep Python's plain `Error: Failed to read JSON: …` line, like the file read
    /// failures above; the structured payload starts at the per-item validation gate.
    private static func readPipedDocument(_ stdin: StandardInput) -> PipedDocument {
        guard !stdin.isInteractive() else {
            return .refused(.error("Failed to read JSON: import - requires piped standard input"))
        }
        let data = stdin.read(maxPipedDocumentBytes)
        guard data.count <= maxPipedDocumentBytes else {
            return .refused(.error("Failed to read JSON: standard input exceeds 8 MiB"))
        }
        return .document(data)
    }

    private enum PipedDocument {
        case document(Data)
        case refused(WriteOutcome)
    }

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
    @Argument(help: "Shell to generate completions for (bash, zsh, fish)") var shell: ShellChoice = .zsh
    func run() throws {
        let script: String
        switch shell {
        case .zsh:  script = CompletionScripts.zsh
        case .bash: script = CompletionScripts.bash
        case .fish: script = CompletionScripts.fish
        }
        // Use FileHandle to avoid print()'s implicit newline; script already ends with \n.
        FileHandle.standardOutput.write(Data(script.utf8))
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Diagnose setup and permissions.")
    @Flag(name: .customLong("for-agent"), help: "Print agent-focused context and TCC guidance.") var forAgent = false
    @Flag(name: .long, help: "Output machine-readable JSON.") var json = false
    @Flag(name: .long, help: "Disable ANSI color.") var noColor = false

    func run() throws {
        let checks = gatherDoctorChecks(probes: DoctorRuntime.realProbes())
        let context = doctorExecutionContext()
        let (result, failCount, _) = DoctorRuntime.buildResult(checks: checks, context: context, forAgent: forAgent)

        if json {
            print(result.serialized(indent: 2, ensureAscii: false))
        } else {
            let ansi = Ansi.resolve(noColorFlag: noColor)
            var lines: [String] = [ansi.bold("RemCTL doctor")]
            func ctxStr(_ key: String) -> String? {
                if case let .string(v)? = context[key] { return v }; return nil
            }
            lines.append("Context: \(ctxStr("effective_context") ?? "unknown")")
            lines.append("Python: \(ctxStr("python") ?? "")")
            if case let .object(parent)? = context["parent_process"] {
                let dict = Dictionary(parent, uniquingKeysWith: { a, _ in a })
                if case let .string(name)? = dict["name"], case let .int(pid)? = dict["pid"] {
                    lines.append("Parent process: \(name) (pid \(pid))")
                }
            }
            if let host = ctxStr("host_app") { lines.append("Host app: \(host)") }
            if let term = ctxStr("terminal_app") { lines.append("Terminal app: \(term)") }
            if forAgent { lines.append(DoctorRuntime.agentNoteHuman) }
            lines.append("")  // blank line before the report
            print(lines.joined(separator: "\n"))
            print(printCheckReport(title: nil, checks: checks, ansi: ansi))
        }

        if failCount > 0 { throw ExitCode(1) }
    }
}

struct Onboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "onboard", abstract: "First-run onboarding.")
    @Flag(name: .long, help: "Output machine-readable JSON.") var json = false
    @Flag(name: .long, help: "Disable ANSI color.") var noColor = false

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let ansi = Ansi.resolve(noColorFlag: noColor, env: env)

        let outcome = await Self.perform(
            auto: false,
            json: json,
            storeAccessError: Paths.storeAccessError(),
            dbPath: Paths.findMainDBPath()?.path,
            now: Date(),
            env: env,
            ansi: json ? Ansi(enabled: false) : ansi,
            // REAL seams — all the actual GUI/TCC/clipboard side effects live here.
            openApp: { Self.realOpenReminders() },
            eventKitAuthorize: { await Self.realEventKitAuthorize() },
            automationProbe: { Self.realAutomationProbe() },
            openSettings: { args in Self.realOpen(args) },
            copyClipboard: { text in copyToClipboard(text) }
        )

        if !outcome.stdout.isEmpty { print(outcome.stdout, terminator: "") }
        if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data(outcome.stderr.utf8)) }
        if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }

    // ── Real side-effect implementations (live-only; never run in CI) ─────────

    /// `open -a Reminders` + a brief settle. Best-effort; never surfaces failure.
    private static func realOpenReminders() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Reminders"]
        try? proc.run()
        proc.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)
    }

    /// In-process EventKit authorize (the TCC prompt). On success, build the
    /// granted detail referencing the remctl binary + calendarCount/defaultList,
    /// matching the Python ok-detail shape. On failure, FAIL with the same-terminal
    /// fix. The Python bridge-binary WARN variants are dropped (in-process reality).
    private static func realEventKitAuthorize() async -> OnboardProbeResult {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "remctl"
        do {
            let summary = try await EventKitWriter().authorize()
            let n = summary.calendarCount
            let defaultList = summary.defaultList.isEmpty ? "unknown" : summary.defaultList
            let detail = "Reminders access granted to \(binary) (\(n) list\(n == 1 ? "" : "s"), default: \(defaultList))."
            return (true, detail, nil)
        } catch let e as WriteError {
            return (false, e.message,
                    "Re-run `remctl onboard` from the same terminal and click Allow when macOS asks for Reminders access.")
        } catch {
            return (false, "Reminders authorization failed.",
                    "Re-run `remctl onboard` from the same terminal and click Allow when macOS asks for Reminders access.")
        }
    }

    /// osascript Automation probe (the Apple Events TCC prompt). Mirrors
    /// `applescript_access_check_for_onboarding` (remctl:3604).
    private static func realAutomationProbe() -> OnboardProbeResult {
        let script = "tell application \"Reminders\" to get name of default list"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (false, "Could not run osascript: \(error.localizedDescription)",
                    "Re-run `remctl onboard` from Terminal after opening Reminders.app.")
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus == 0 {
            let detail = stdout.isEmpty
                ? "AppleScript automation access confirmed."
                : "AppleScript automation access confirmed (default list: \(stdout))."
            return (true, detail, nil)
        }
        let message = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "AppleScript automation probe failed.")
        return (false, message,
                "Re-run `remctl onboard` from the same terminal and approve the Automation prompt if macOS asks. Flagged operations and AppleScript fallback writes rely on this access.")
    }

    /// `/usr/bin/open <args>` returning the exit code (the `openSettings` seam).
    private static func realOpen(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        do { try proc.run(); proc.waitUntilExit(); return proc.terminationStatus }
        catch { return 1 }
    }
}

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Guided Full Disk Access setup.")

    // Topic is a RAW String (not an enum) so that unsupported values produce
    // exit 1 + our exact error message rather than ArgumentParser's exit 64.
    // Port of `a.topic != 'full-disk-access'` guard in `cmd_permissions` (remctl:7495).
    @Argument(help: "Permissions topic (full-disk-access).") var topic: String

    @Flag(name: .long, help: "Wait for the helper to exit before returning.") var wait = false
    @Flag(name: .long, help: "Output machine-readable JSON.") var json = false

    func run() throws {
        let outcome = try Self.perform(
            topic: topic,
            wait: wait,
            json: json,
            env: ProcessInfo.processInfo.environment
        )
        if !outcome.stdout.isEmpty { print(outcome.stdout, terminator: "") }
        if !outcome.stderr.isEmpty {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }

    // ── Testable core ──────────────────────────────────────────────────────
    struct Outcome { let stdout: String; let stderr: String; let exitCode: Int32 }

    /// Port of `cmd_permissions` (remctl:7494). Pure of process-level GUI/clipboard
    /// side effects when called with injected `openSettings`/`runPbcopy` closures.
    ///
    /// - `openSettings`: called in human mode to open System Settings (returns
    ///   whether it launched). Injected as a no-op in JSON mode and tests.
    /// - `runPbcopy`: called in human mode guidance to copy the runtime path to
    ///   the clipboard. Injected as a no-op in JSON mode and tests.
    static func perform(
        topic: String,
        wait: Bool,
        json: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment,
        openSettings: ([String]) -> Int32 = { args in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = args
            do { try proc.run(); proc.waitUntilExit(); return proc.terminationStatus } catch { return 1 }
        },
        runPbcopy: (String) -> Bool = { text in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let pipe = Pipe(); proc.standardInput = pipe
            do {
                try proc.run()
                pipe.fileHandleForWriting.write(Data(text.utf8))
                try? pipe.fileHandleForWriting.close()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch { return false }
        }
    ) throws -> Outcome {
        // 1. Topic validation — raw String guard (preserves exit 1 + exact message).
        if topic != "full-disk-access" {
            return Outcome(
                stdout: "",
                stderr: "Error: Unsupported permissions topic '\(topic)'\n",
                exitCode: 1
            )
        }

        // 2. Build targets + result dict.
        let targets = fullDiskAccessTargetSpecs(includeCli: true, env: env)
        let targetsValue: JSONValue = .array(targets.map { pairs in JSONValue.object(pairs) })
        let helperPath = currentPermissionsPath(env: env)

        let resultPairs: [(String, JSONValue)] = [
            ("helper", .string(helperPath)),
            ("available", .bool(permissionHelperAvailable())),
            ("targets", targetsValue),
        ]

        // 3. JSON mode — serialize and return (NO GUI/Settings/clipboard).
        if json {
            let out = JSONValue.object(resultPairs).serialized(indent: 2, ensureAscii: false) + "\n"
            return Outcome(stdout: out, stderr: "", exitCode: 0)
        }

        // 4. Human mode — helper always returns false (no bundled helper), so go
        //    straight to guidance. Exit 0 even if Settings couldn't be opened.
        _ = launchFullDiskAccessHelper(includeCli: true, wait: wait)
        let settingsOpened = openFullDiskAccessSettings(open: openSettings)
        let ansi = Ansi.resolve(noColorFlag: false)
        let guidance = printFullDiskAccessGuidance(
            settingsOpened: settingsOpened,
            rerunCommand: "remctl doctor",
            ansi: ansi,
            env: env,
            runPbcopy: runPbcopy
        )
        return Outcome(stdout: guidance + "\n", stderr: "", exitCode: 0)
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Install shell completions/config.")
    @Option(name: .long, help: "Shell to configure (auto, bash, zsh, fish, skip)") var shell: String = "auto"
    @Flag(name: .long, help: "Also run a doctor check after setup.") var doctor = false
    @Flag(name: .long, help: "Output machine-readable JSON.") var json = false

    func run() throws {
        let outcome = try Self.perform(shellArg: shell, doctor: doctor, json: json)
        if !outcome.stdout.isEmpty {
            // Use FileHandle to avoid print()'s implicit newline when the output already ends with \n.
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if !outcome.stderr.isEmpty {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }

    // ── Testable core ──────────────────────────────────────────────────────
    struct Outcome { let stdout: String; let stderr: String; let exitCode: Int32 }

    /// Port of `cmd_setup` (remctl:7516). Pure of process-level side effects when given
    /// an injected `env`; does write to the filesystem (config dir + completion file).
    @discardableResult
    static func perform(
        shellArg: String,
        doctor: Bool,
        json: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Outcome {
        let fm = FileManager.default

        // Step 1: mkdir -p CONFIG_DIR + best-effort chmod 0700.
        let configDir = Paths.resolveConfigDir(env: env)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: nil)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)

        // Step 2: resolve shell.
        let selectedShell = resolveSetupShell(shellArg, env: env)

        // Step 3: install completion (unless skip).
        var completionPath: URL? = nil
        if selectedShell != "skip" {
            completionPath = try installCompletion(selectedShell, env: env)
        }

        // Step 4: build result.
        var pairs: [(String, JSONValue)] = [
            ("ok", .bool(true)),
            ("config_dir", .string(configDir.path)),
            ("completion_shell", selectedShell == "skip" ? .null : .string(selectedShell)),
            ("completion_path", completionPath.map { .string($0.path) } ?? .null),
        ]

        // Step 5: --doctor (smaller shape: only ok + checks, no warnings/failures/context).
        if doctor {
            let checks = gatherDoctorChecks(probes: DoctorRuntime.realProbes(env: env))
            let failCount = checks.filter { $0.status == .fail }.count
            let checkPairs: [JSONValue] = checks.map { c in
                .object([
                    ("name", .string(c.name)),
                    ("status", .string(c.status.rawValue)),
                    ("detail", .string(c.detail)),
                    ("fix", c.fix.map { JSONValue.string($0) } ?? .null),
                ])
            }
            let doctorValue: JSONValue = .object([
                ("ok", .bool(failCount == 0)),
                ("checks", .array(checkPairs)),
            ])
            pairs.append(("doctor", doctorValue))
        }

        let result: JSONValue = .object(pairs)

        // Step 6: output.
        var stdout = ""
        let stderr = ""
        var exitCode: Int32 = 0

        if json {
            stdout = result.serialized(indent: 2, ensureAscii: false) + "\n"
        } else {
            // Human output — NO_COLOR / color-detection identical to doctor.
            let ansi = Ansi.resolve(
                noColorFlag: false,
                env: env,
                isTTY: isatty(STDOUT_FILENO) != 0)
            var lines: [String] = []
            lines.append(ansi.bold("RemCTL setup"))
            lines.append("Config directory: \(configDir.path)")
            if let path = completionPath {
                lines.append("Shell completion: \(path.path)")
            } else {
                lines.append("Shell completion: skipped")
            }
            if selectedShell == "zsh", let path = completionPath {
                lines.append("")
                lines.append(ansi.bold("Enable zsh completions:"))
                lines.append("  Add these lines to ~/.zshrc, then open a new terminal:")
                lines.append("    fpath=(\(path.deletingLastPathComponent().path) $fpath)")
                lines.append("    autoload -Uz compinit && compinit")
            }
            lines.append("")
            lines.append("Next:")
            lines.append("  1. remctl onboard   # trigger macOS Reminders and Automation prompts")
            lines.append("  2. remctl permissions full-disk-access   # visual Full Disk Access setup")
            lines.append("  3. remctl doctor    # verify the CLI")
            stdout = lines.joined(separator: "\n") + "\n"

            // --doctor in human mode: re-run doctor report (may exit 1 on any FAIL).
            if doctor {
                let checks = gatherDoctorChecks(probes: DoctorRuntime.realProbes(env: env))
                let failCount = checks.filter { $0.status == .fail }.count
                stdout += "\n" + printCheckReport(title: nil, checks: checks, ansi: ansi) + "\n"
                if failCount > 0 { exitCode = 1 }
            }
        }

        return Outcome(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}

/// Port of `install_completion(shell)` (remctl:6976).
/// Creates parent directories, writes the completion script, returns the target URL.
/// NO 0600 chmod on the output file.
@discardableResult
func installCompletion(_ shell: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
    let target = try completionTargetPath(shell, env: env)
    let parent = target.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
    let script = try completionScript(for: shell)
    try script.write(to: target, atomically: true, encoding: .utf8)
    return target
}
