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
                json: json, store: store, writer: writer, private: priv)
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
    ///   3. `flagged: true` items: with P12 the imply-rule routes `--flag` ALONE through the
    ///      PUBLIC EventKit priority-proxy (no private-only flag is set during import), so such
    ///      items now succeed (and count as `created`) rather than erroring. The private writer is
    ///      threaded through but never invoked, since import never sets a private-only flag.
    static func perform(
        path: String,
        readFile: (String) -> Data?,
        json: Bool, store: RemindersStore, writer: RemindersWriter, private priv: PrivateWriter,
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
                    json: false, store: store, writer: writer, private: priv, now: now, calendar: calendar)
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
