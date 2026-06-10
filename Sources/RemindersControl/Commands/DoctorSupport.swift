import Foundation
import EventKit
import ReminderKitPrivate

// ──────────────────────────────────────────────────────────────────────────────
// Doctor — read-only diagnostic, ADAPTED to the in-process Swift reality.
//
// Source of truth: `gather_doctor_checks` (remctl:7320), `cmd_doctor` (:7429),
// `print_check_report` (:3149), `doctor_execution_context` (:3270),
// `full_disk_access_fix_text` (:3385).
//
// RE-FRAMINGS vs the Python source (intentional, documented contract change —
// Q7 updates the spec):
//   • python            → `macos`     (runtime/OS-version check; always ok)
//   • bridge            → `eventkit`  (in-process EKEventStore auth; WARN not fail)
//   • private_helper    → `reminderkit` (in-process RKPProbe; WARN not fail)
//   • permissions_helper→ DROPPED      (no separate permissions binary in-process)
//
// All re-framed checks stay WARN (never FAIL) to preserve exit-code parity:
// doctor exits 1 IFF a check FAILED, and only platform/macos/store_dir/database/cli
// can fail. EventKit/ReminderKit unavailability never forces a non-zero exit.
// ──────────────────────────────────────────────────────────────────────────────

/// One diagnostic line. Mirrors the Python check dict `{name,status,detail,fix}`.
public struct DoctorCheck: Equatable, Sendable {
    public enum Status: String, Sendable { case ok, warn, fail }
    public let name: String
    public let status: Status
    public let detail: String
    public let fix: String?
    public init(name: String, status: Status, detail: String, fix: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}

/// Injected probe values/closures — the pure CI seam. The command builds REAL probes
/// (filesystem/EventKit/RKP); tests inject fixtures. Each field corresponds to a
/// piece of environment state that `gather_doctor_checks` reads directly.
public struct DoctorProbes: Sendable {
    /// `sys.platform == "darwin"` analogue.
    public var isDarwin: Bool
    /// `platform` check detail, e.g. "Darwin 25.5.0" / "macOS 15.5".
    public var platformDetail: String
    /// The re-framed `macos` check detail, e.g. "macOS 15.5".
    public var macOSDetail: String

    /// `str(STORE_DIR)` and whether it exists.
    public var storeDirPath: String
    public var storeDirExists: Bool
    /// `reminders_store_access_error()` — non-nil FDA-blocked message when the store
    /// dir exists but is unreadable.
    public var storeAccessError: String?
    /// `str(find_main_db_path())` or nil when no Data-*.sqlite found.
    public var dbPath: String?

    /// `str(current_cli_path())` and whether that path exists / is on $PATH.
    public var cliPath: String
    public var cliExists: Bool
    public var cliOnPath: Bool

    /// In-process EventKit authorization status (NON-PROMPTING).
    public var eventKitAuthStatus: EKAuthorizationStatus
    /// `RKPProbe()` result — "reminderkit-ok" / "reminderkit-missing".
    public var reminderKitProbeResult: String

    /// `str(CONFIG_DIR)` and whether it exists.
    public var configDirPath: String
    public var configDirExists: Bool

    /// `detect_shell_name()` result.
    public var shellName: String
    /// `str(completion_target_path(shell))` (nil when shell is unsupported) and existence.
    public var completionTargetPath: String?
    public var completionTargetExists: Bool
    /// `zsh_completion_loadable` result; nil when not applicable (non-zsh shell or
    /// missing completion file) — then no completion_fpath check is emitted.
    public var completionFpathLoadable: Bool?

    /// The full-disk-access fix text builder (closure so tests can inject a stub; the
    /// command supplies the real, environment-dependent text).
    public var fullDiskAccessFixText: @Sendable () -> String

    public init(
        isDarwin: Bool,
        platformDetail: String,
        macOSDetail: String,
        storeDirPath: String,
        storeDirExists: Bool,
        storeAccessError: String?,
        dbPath: String?,
        cliPath: String,
        cliExists: Bool,
        cliOnPath: Bool,
        eventKitAuthStatus: EKAuthorizationStatus,
        reminderKitProbeResult: String,
        configDirPath: String,
        configDirExists: Bool,
        shellName: String,
        completionTargetPath: String?,
        completionTargetExists: Bool,
        completionFpathLoadable: Bool? = nil,
        fullDiskAccessFixText: @escaping @Sendable () -> String
    ) {
        self.isDarwin = isDarwin
        self.platformDetail = platformDetail
        self.macOSDetail = macOSDetail
        self.storeDirPath = storeDirPath
        self.storeDirExists = storeDirExists
        self.storeAccessError = storeAccessError
        self.dbPath = dbPath
        self.cliPath = cliPath
        self.cliExists = cliExists
        self.cliOnPath = cliOnPath
        self.eventKitAuthStatus = eventKitAuthStatus
        self.reminderKitProbeResult = reminderKitProbeResult
        self.configDirPath = configDirPath
        self.configDirExists = configDirExists
        self.shellName = shellName
        self.completionTargetPath = completionTargetPath
        self.completionTargetExists = completionTargetExists
        self.completionFpathLoadable = completionFpathLoadable
        self.fullDiskAccessFixText = fullDiskAccessFixText
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Check gathering — pure function of the injected probes.
// ──────────────────────────────────────────────────────────────────────────────

/// Build the ordered list of diagnostic checks from injected probes. Pure (no I/O):
/// the only side-effecting work happens when the command CONSTRUCTS the probes.
///
/// Order (re-framed): platform, macos, store_dir, database, cli, eventkit,
/// reminderkit, config_dir, completion. (Python had: platform, python, store_dir,
/// database, cli, bridge, private_helper, permissions_helper, config_dir, completion —
/// `python`→`macos`, `bridge`→`eventkit`, `private_helper`→`reminderkit`,
/// `permissions_helper` DROPPED.)
public func gatherDoctorChecks(probes p: DoctorProbes) -> [DoctorCheck] {
    var checks: [DoctorCheck] = []

    // 1. platform — ok iff darwin else FAIL.
    checks.append(DoctorCheck(
        name: "platform",
        status: p.isDarwin ? .ok : .fail,
        detail: p.platformDetail,
        fix: p.isDarwin ? nil : "RemCTL only supports macOS."))

    // 2. macos (RE-FRAME of `python`) — informative slot, always ok. There is no
    //    Python interpreter to version-gate; report the macOS version instead.
    checks.append(DoctorCheck(
        name: "macos",
        status: .ok,
        detail: p.macOSDetail,
        fix: nil))

    // 3. store_dir — ok iff exists else FAIL.
    checks.append(DoctorCheck(
        name: "store_dir",
        status: p.storeDirExists ? .ok : .fail,
        detail: p.storeDirPath,
        fix: p.storeDirExists ? nil : "Set REMCTL_STORE_DIR if your Reminders store lives elsewhere."))

    // 4. database — two mutually exclusive branches.
    if let accessError = p.storeAccessError {
        // Store dir exists but is unreadable → FDA blocked.
        checks.append(DoctorCheck(
            name: "database",
            status: .fail,
            detail: accessError,
            fix: p.fullDiskAccessFixText()))
    } else {
        let hasDB = p.dbPath != nil
        checks.append(DoctorCheck(
            name: "database",
            status: hasDB ? .ok : .fail,
            detail: p.dbPath ?? "No Reminders database found",
            fix: hasDB ? nil : "Enable iCloud Reminders and open Reminders.app once, or run remctl onboard."))
    }

    // 5. cli — status keys off existence; fix keys off PATH-presence (PRESERVED quirk:
    //    a present-but-not-on-PATH binary shows OK *with* a fix string).
    checks.append(DoctorCheck(
        name: "cli",
        status: p.cliExists ? .ok : .fail,
        detail: p.cliPath,
        fix: p.cliOnPath ? nil : "Add \(parentDirectory(p.cliPath)) to PATH."))

    // 6. eventkit (RE-FRAME of `bridge`) — in-process EventKit auth. WARN (never FAIL).
    //    .fullAccess (macOS 14+ API) OR legacy .authorized both map to ok across OS
    //    versions. Both share rawValue 3 (`.authorized` was renamed to `.fullAccess`),
    //    so a rawValue==3 comparison covers both without touching the deprecated case.
    let ekOK = p.eventKitAuthStatus == .fullAccess || p.eventKitAuthStatus.rawValue == 3
    checks.append(DoctorCheck(
        name: "eventkit",
        status: ekOK ? .ok : .warn,
        detail: eventKitStatusDescription(p.eventKitAuthStatus),
        fix: ekOK ? nil : "Reminders access is not granted; run remctl onboard to grant EventKit access."))

    // 7. reminderkit (RE-FRAME of `private_helper`) — in-process RKPProbe. WARN (never FAIL).
    let rkOK = p.reminderKitProbeResult == "reminderkit-ok"
    checks.append(DoctorCheck(
        name: "reminderkit",
        status: rkOK ? .ok : .warn,
        detail: p.reminderKitProbeResult,
        fix: rkOK ? nil : "The private ReminderKit framework is unavailable; --private writes will not work."))

    // (permissions_helper DROPPED — no analog in-process.)

    // 8. config_dir — ok iff exists else WARN.
    checks.append(DoctorCheck(
        name: "config_dir",
        status: p.configDirExists ? .ok : .warn,
        detail: p.configDirPath,
        fix: p.configDirExists ? nil : "Run remctl setup to create config files."))

    // 9. completion — supported-shell vs unsupported-shell branches.
    if ["zsh", "bash", "fish"].contains(p.shellName), let target = p.completionTargetPath {
        checks.append(DoctorCheck(
            name: "completion",
            status: p.completionTargetExists ? .ok : .warn,
            detail: "\(p.shellName): \(target)",
            fix: p.completionTargetExists ? nil : "Run remctl setup --shell \(p.shellName) to install completion."))
        // 9a. completion_fpath (upstream aba7cf5) — zsh-only: an installed completion
        //     that zsh can't load is indistinguishable from a missing one to the user.
        if p.shellName == "zsh", p.completionTargetExists, let loadable = p.completionFpathLoadable {
            let dir = parentDirectory(target)
            if loadable {
                checks.append(DoctorCheck(
                    name: "completion_fpath", status: .ok,
                    detail: "\(dir) is on zsh fpath", fix: nil))
            } else {
                checks.append(DoctorCheck(
                    name: "completion_fpath", status: .warn,
                    detail: "\(dir) is not on zsh fpath",
                    fix: zshCompletionHint(URL(fileURLWithPath: target))))
            }
        }
    } else {
        checks.append(DoctorCheck(
            name: "completion",
            status: .warn,
            detail: "Unsupported shell '\(p.shellName)'",
            fix: "Run remctl setup --shell zsh|bash|fish."))
    }

    return checks
}

/// `Path(cli_path).parent` analogue: the directory component of a path string.
func parentDirectory(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().path
}

/// Human description of an EventKit authorization status (used as the `eventkit`
/// check detail).
func eventKitStatusDescription(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .fullAccess: return "Full access granted"
    case .authorized: return "Access granted"
    case .writeOnly: return "Write-only access (no read access to reminders)"
    case .notDetermined: return "Not determined (no prompt has been shown)"
    case .restricted: return "Restricted by system policy"
    case .denied: return "Access denied"
    @unknown default: return "Unknown authorization status (\(status.rawValue))"
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// print_check_report (remctl:3149) — exact format port.
// ──────────────────────────────────────────────────────────────────────────────

/// Render the check report EXACTLY like Python's `print_check_report`:
///   • optional bold title line
///   • per check: `[<LABEL>] <name>: <detail>` (LABEL colored OK/WARN/FAIL)
///   • each fix line indented 6 spaces, dim
///   • a colored, pluralized summary `<N> checks, <W> warning(s), <F> failure(s)`
///     (red if any fail, else yellow if any warn, else green)
/// Returns the rendered string (newline-terminated lines joined; no trailing newline
/// beyond the last line's). doctor passes `title: nil`.
public func printCheckReport(title: String?, checks: [DoctorCheck], ansi: Ansi) -> String {
    let failCount = checks.filter { $0.status == .fail }.count
    let warnCount = checks.filter { $0.status == .warn }.count

    func label(_ s: DoctorCheck.Status) -> String {
        switch s {
        case .ok:   return ansi.green("OK")
        case .warn: return ansi.yellow("WARN")
        case .fail: return ansi.red("FAIL")
        }
    }

    var lines: [String] = []
    if let title { lines.append(ansi.bold(title)) }
    for check in checks {
        lines.append("[\(label(check.status))] \(check.name): \(check.detail)")
        if let fix = check.fix, !fix.isEmpty {
            for line in fix.components(separatedBy: "\n") {
                lines.append("      \(ansi.dim(line))")
            }
        }
    }
    let summary = "\(checks.count) checks, "
        + "\(warnCount) warning\(warnCount != 1 ? "s" : ""), "
        + "\(failCount) failure\(failCount != 1 ? "s" : "")"
    if failCount > 0 {
        lines.append(ansi.red(summary))
    } else if warnCount > 0 {
        lines.append(ansi.yellow(summary))
    } else {
        lines.append(ansi.green(summary))
    }
    return lines.joined(separator: "\n")
}

// ──────────────────────────────────────────────────────────────────────────────
// Execution context — best-effort process/terminal introspection (degrade-only).
// Port of `doctor_execution_context` (remctl:3270) + helpers. NEVER throws; on any
// failure (ps/mdfind timeout, no ancestry) it degrades to effective_context "unknown".
// ──────────────────────────────────────────────────────────────────────────────

/// Maps a normalized process/terminal name to its `.app` bundle name.
/// Port of `KNOWN_TERMINAL_APPS` (remctl:62).
let knownTerminalApps: [String: String] = [
    "alacritty": "Alacritty.app",
    "apple_terminal": "Terminal.app",
    "code": "Visual Studio Code.app",
    "cursor": "Cursor.app",
    "ghostty": "Ghostty.app",
    "hyper": "Hyper.app",
    "iterm.app": "iTerm.app",
    "iterm2": "iTerm.app",
    "kitty": "kitty.app",
    "terminal": "Terminal.app",
    "visual studio code": "Visual Studio Code.app",
    "warp": "Warp.app",
    "warpterminal": "Warp.app",
    "wezterm-gui": "WezTerm.app",
    "zed": "Zed.app",
]

func normalizeTerminalAppName(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return knownTerminalApps[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
}

/// Port of `_app_name_from_process_name` (remctl:3261): 'codex' special-case.
func appNameFromProcessName(_ name: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    if name.lowercased().contains("codex") { return "Codex.app" }
    return normalizeTerminalAppName(name)
}

/// Run `ps` with the given args, returning trimmed stdout or nil on failure/timeout.
/// Swallows OSError/timeout (best-effort), matching the Python `try/except`.
private func runPS(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = args
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    do { try p.run() } catch { return nil }
    // Best-effort 5s timeout (mirrors subprocess timeout=5).
    let deadline = Date().addingTimeInterval(5)
    while p.isRunning && Date() < deadline { usleep(10_000) }
    if p.isRunning { p.terminate(); return nil }
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let s = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

struct ProcessNode { let pid: Int; let ppid: Int?; let name: String; let command: String }

/// Port of `process_info` (remctl:3220): `ps -p PID -o ppid= -o ucomm= -o command=`.
func processInfo(pid: Int) -> ProcessNode? {
    guard let line = runPS(["-p", String(pid), "-o", "ppid=", "-o", "ucomm=", "-o", "command="]) else { return nil }
    // split(None, 2) — at most 3 parts on whitespace.
    let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }.map(String.init)
    guard parts.count >= 2 else { return nil }
    let ppid = Int(parts[0])
    let name = parts[1]
    let command = parts.count > 2 ? parts[2] : name
    return ProcessNode(pid: pid, ppid: ppid, name: name, command: command)
}

/// Port of `process_ancestry` (remctl:3247): walk up to `limit` parents from getppid().
func processAncestry(limit: Int = 8) -> [ProcessNode] {
    var ancestry: [ProcessNode] = []
    var pid = Int(getppid())
    for _ in 0..<limit {
        guard pid > 1 else { break }
        guard let info = processInfo(pid: pid) else { break }
        ancestry.append(info)
        guard let next = info.ppid else { break }
        pid = next
    }
    return ancestry
}

/// Port of `detect_terminal_app_name` (remctl:3183): TERM_PROGRAM env, then a 6-level
/// `ps -o ppid= -o comm=` walk against KNOWN_TERMINAL_APPS.
func detectTerminalAppName(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    if let name = normalizeTerminalAppName(env["TERM_PROGRAM"]) { return name }
    var pid = Int(getppid())
    for _ in 0..<6 {
        guard pid > 1 else { break }
        guard let line = runPS(["-o", "ppid=", "-o", "comm=", "-p", String(pid)]) else { break }
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }.map(String.init)
        guard parts.count == 2 else { break }
        let command = parts[1]
        let label = normalizeTerminalAppName(URL(fileURLWithPath: command).lastPathComponent)
        if let label { return label }
        guard let next = Int(parts[0]) else { break }
        pid = next
    }
    return nil
}

/// Extract an existing `.app` bundle from a path-ish string. Port of
/// `app_bundle_from_path_hint` (upstream aba7cf5): first `/…​.app` segment, tilde-
/// expanded, must exist.
func appBundleFromPathHint(_ value: String?) -> URL? {
    guard let value, !value.isEmpty else { return nil }
    guard let re = try? NSRegularExpression(pattern: #"(/.*?\.app)(?:/|\s|$)"#) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let m = re.firstMatch(in: value, options: [], range: range),
          let r = Range(m.range(at: 1), in: value) else { return nil }
    let path = (String(value[r]) as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.lastPathComponent.hasSuffix(".app"),
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
}

/// Resolve an app bundle path from a bundle identifier via Spotlight. Port of
/// `find_app_bundle_by_identifier` (upstream aba7cf5): mdfind with a 5s timeout;
/// nil on any failure. The id must look like a bundle id (defends the query string).
func findAppBundleByIdentifier(_ bundleId: String?) -> URL? {
    guard let bundleId, !bundleId.isEmpty,
          bundleId.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemCFBundleIdentifier == '\(bundleId)'"]
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    do { try p.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(5)
    while p.isRunning && Date() < deadline { usleep(10_000) }
    if p.isRunning { p.terminate(); return nil }
    guard p.terminationStatus == 0 else { return nil }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        let url = URL(fileURLWithPath: (line as NSString).expandingTildeInPath)
        if url.lastPathComponent.hasSuffix(".app"), FileManager.default.fileExists(atPath: url.path) {
            return url.standardizedFileURL
        }
    }
    return nil
}

/// The host-app bundle resolved from the ENVIRONMENT (not the process tree). Port of
/// `bundle_context_from_environment` (upstream aba7cf5): `__CFBundleIdentifier` via
/// Spotlight first, then Ghostty's resource-path variables — embedded terminals
/// inherit `TERM_PROGRAM=ghostty`, so the env bundle is the real FDA target.
struct BundleContext: Equatable {
    let app: String
    let path: String
    let bundleId: String?
    let source: String
}

func bundleContextFromEnvironment(
    env: [String: String] = ProcessInfo.processInfo.environment,
    bundleResolver: (String) -> URL? = { findAppBundleByIdentifier($0) }
) -> BundleContext? {
    let bundleId = env["__CFBundleIdentifier"]
    if let bundleId, let bundle = bundleResolver(bundleId) {
        return BundleContext(app: bundle.lastPathComponent, path: bundle.path,
                             bundleId: bundleId, source: "__CFBundleIdentifier")
    }
    for envName in ["GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR"] {
        if let bundle = appBundleFromPathHint(env[envName]) {
            return BundleContext(app: bundle.lastPathComponent, path: bundle.path,
                                 bundleId: bundleId, source: envName)
        }
    }
    return nil
}

/// The host-app resolution over the process ancestry, seeded by the env bundle
/// context. Pure (ancestry + lookups injected) so the Ghostty-skip logic is testable.
func resolveHostContext(
    ancestry: [ProcessNode],
    terminalApp: String?,
    bundleContext: BundleContext?,
    findBundle: (String) -> URL? = { findAppBundle($0) }
) -> (hostApp: String?, hostAppPath: String?, hostBundleId: String?, hostAppSource: String?, effectiveContext: String) {
    var hostApp = bundleContext?.app ?? terminalApp
    var hostAppPath = bundleContext?.path
    let hostBundleId = bundleContext?.bundleId
    var hostAppSource = bundleContext?.source ?? (terminalApp != nil ? "terminal" : nil)
    var effectiveContext = terminalApp != nil ? "Terminal" : "unknown"

    loop: for proc in ancestry {
        if let appName = appNameFromProcessName(proc.name) {
            // An embedded terminal's ghostty process must not shadow the real
            // embedder app the environment identified (upstream aba7cf5).
            if let bundleContext, appName == "Ghostty.app", bundleContext.app != "Ghostty.app" {
                continue
            }
            hostApp = appName
            if appName.hasSuffix(".app"), let resolved = findBundle(appName) {
                hostAppPath = resolved.path
            }
            hostAppSource = "process"
            if appName.lowercased().contains("codex") {
                effectiveContext = "Codex"
            } else if appName.hasSuffix(".app") {
                effectiveContext = String(appName.dropLast(4))
            }
            break loop
        }
        if let bundle = appBundleFromPathHint(proc.command) {
            hostApp = bundle.lastPathComponent
            hostAppPath = bundle.path
            hostAppSource = "process_command"
            effectiveContext = String(bundle.lastPathComponent.dropLast(4))
            break loop
        }
    }
    if let bundleContext, hostApp == bundleContext.app {
        effectiveContext = String(bundleContext.app.hasSuffix(".app")
            ? String(bundleContext.app.dropLast(4)) : bundleContext.app)
    }
    return (hostApp, hostAppPath, hostBundleId, hostAppSource, effectiveContext)
}

/// Port of `doctor_execution_context` (remctl:3270 + aba7cf5). Keys: `python`
/// (re-framed to the remctl binary/runtime path), `pid`, `parent_process`,
/// `terminal_app`, `host_app`, `host_app_path`, `host_bundle_id`,
/// `host_app_source`, `effective_context`. Best-effort: degrades to "unknown".
public func doctorExecutionContext(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [String: JSONValue] {
    let ancestry = processAncestry()
    let parent = ancestry.first
    let terminalApp = detectTerminalAppName(env: env)
    let bundleContext = bundleContextFromEnvironment(env: env)
    let host = resolveHostContext(ancestry: ancestry, terminalApp: terminalApp,
                                  bundleContext: bundleContext)

    // `python` → the running remctl binary/runtime path (Bundle.main.executablePath).
    let runtimePath = Bundle.main.executablePath
        ?? CommandLine.arguments.first
        ?? "remctl"

    let parentValue: JSONValue
    if let parent {
        parentValue = .object([
            ("pid", .int(parent.pid)),
            ("ppid", parent.ppid.map { JSONValue.int($0) } ?? .null),
            ("name", .string(parent.name)),
            ("command", .string(parent.command)),
        ])
    } else {
        parentValue = .null
    }

    return [
        "python": .string(runtimePath),
        "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
        "parent_process": parentValue,
        "terminal_app": terminalApp.map { JSONValue.string($0) } ?? .null,
        "host_app": host.hostApp.map { JSONValue.string($0) } ?? .null,
        "host_app_path": host.hostAppPath.map { JSONValue.string($0) } ?? .null,
        "host_bundle_id": host.hostBundleId.map { JSONValue.string($0) } ?? .null,
        "host_app_source": host.hostAppSource.map { JSONValue.string($0) } ?? .null,
        "effective_context": .string(host.effectiveContext),
    ]
}

// ──────────────────────────────────────────────────────────────────────────────
// Real-probe construction + the doctor result assembly.
// ──────────────────────────────────────────────────────────────────────────────

public enum DoctorRuntime {
    /// The agent_note text (JSON `agent_note` value + basis for the human Agent-note
    /// line). Copied verbatim from `cmd_doctor` (remctl:7442).
    public static let agentNoteJSON =
        "This report only applies to the process context shown in `context`. "
        + "`doctor` must pass in the same context that will run the write. "
        + "Terminal and Codex or other agent runners can have different Full Disk Access grants."

    /// The human "Agent note:" line (remctl:7461).
    public static let agentNoteHuman =
        "Agent note: `doctor` must pass in the same context that will run the write; "
        + "Terminal may be green while this runner is blocked."

    /// Build the REAL probes by reading the live environment (filesystem, EventKit,
    /// RKP). The non-prompting EventKit status is `EKEventStore.authorizationStatus`.
    public static func realProbes(env: [String: String] = ProcessInfo.processInfo.environment) -> DoctorProbes {
        let fm = FileManager.default

        let storeDir = Paths.resolveStoreDir(env: env)
        let storeDirExists = fm.fileExists(atPath: storeDir.path)
        let accessError = Paths.storeAccessError(storeDir: storeDir)
        let dbURL = accessError == nil ? Paths.findMainDBPath(storeDir: storeDir) : nil

        let configDir = Paths.resolveConfigDir(env: env)
        let configDirExists = fm.fileExists(atPath: configDir.path)

        let cli = currentCLIPath(env: env)
        let cliExists = fm.fileExists(atPath: cli.path)
        let cliOnPath = whichRemctl(env: env) != nil

        let shell = detectShellName(env: env)
        let completionURL = try? completionTargetPath(shell, env: env)
        let completionExists = completionURL.map { fm.fileExists(atPath: $0.path) } ?? false
        let fpathLoadable: Bool? = (shell == "zsh" && completionExists && completionURL != nil)
            ? zshCompletionLoadable(completionURL!, env: env) : nil

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let macDetail = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion)"
            + (osVersion.patchVersion > 0 ? ".\(osVersion.patchVersion)" : "")

        return DoctorProbes(
            isDarwin: true,
            platformDetail: ProcessInfo.processInfo.operatingSystemVersionString,
            macOSDetail: macDetail,
            storeDirPath: storeDir.path,
            storeDirExists: storeDirExists,
            storeAccessError: accessError,
            dbPath: dbURL?.path,
            cliPath: cli.path,
            cliExists: cliExists,
            cliOnPath: cliOnPath,
            eventKitAuthStatus: EKEventStore.authorizationStatus(for: .reminder),
            reminderKitProbeResult: String(cString: RKPProbe()),
            configDirPath: configDir.path,
            configDirExists: configDirExists,
            shellName: shell,
            completionTargetPath: completionURL?.path,
            completionTargetExists: completionExists,
            completionFpathLoadable: fpathLoadable,
            fullDiskAccessFixText: { fullDiskAccessFixText(rerunCommand: "remctl doctor --for-agent", mentionOnboard: true, env: env) })
    }

    /// Assemble the doctor result dict + compute the exit code. Pure given probes and
    /// a context dict, so the command and tests share one code path. Returns the
    /// JSONValue result and whether the process should exit 1 (fail_count > 0).
    public static func buildResult(
        checks: [DoctorCheck],
        context: [String: JSONValue],
        forAgent: Bool
    ) -> (result: JSONValue, failCount: Int, warnCount: Int) {
        let failCount = checks.filter { $0.status == .fail }.count
        let warnCount = checks.filter { $0.status == .warn }.count

        // Preserve the context key order from doctor_execution_context.
        let contextOrder = ["python", "pid", "parent_process", "terminal_app", "host_app",
                            "host_app_path", "host_bundle_id", "host_app_source", "effective_context"]
        let contextPairs: [(String, JSONValue)] = contextOrder.compactMap { key in
            context[key].map { (key, $0) }
        }

        let checkPairs: [JSONValue] = checks.map { c in
            .object([
                ("name", .string(c.name)),
                ("status", .string(c.status.rawValue)),
                ("detail", .string(c.detail)),
                ("fix", c.fix.map { JSONValue.string($0) } ?? .null),
            ])
        }

        var pairs: [(String, JSONValue)] = [
            ("ok", .bool(failCount == 0)),
            ("warnings", .int(warnCount)),
            ("failures", .int(failCount)),
            ("context", .object(contextPairs)),
            ("checks", .array(checkPairs)),
        ]
        if forAgent {
            pairs.append(("agent_note", .string(agentNoteJSON)))
        }
        return (.object(pairs), failCount, warnCount)
    }
}

/// Port of `current_cli_path` (remctl:6990): `which remctl` resolved, else the running
/// binary path.
func currentCLIPath(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let onPath = whichRemctl(env: env) {
        return URL(fileURLWithPath: onPath).resolvingSymlinksInPath()
    }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "remctl"
    return URL(fileURLWithPath: exe).resolvingSymlinksInPath()
}

/// `shutil.which("remctl")` analogue: scan $PATH for an executable named `remctl`.
func whichRemctl(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard let pathVar = env["PATH"], !pathVar.isEmpty else { return nil }
    let fm = FileManager.default
    for dir in pathVar.split(separator: ":", omittingEmptySubsequences: true).map(String.init) {
        let candidate = (dir as NSString).appendingPathComponent("remctl")
        if fm.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

// ──────────────────────────────────────────────────────────────────────────────
// full_disk_access_fix_text (remctl:3385) — best-effort port. Builds the multi-line
// FDA guidance used as the `database`-FAIL fix. Environment-dependent (calls into
// execution context + app-bundle discovery), so it's exercised live, not in CI.
// ──────────────────────────────────────────────────────────────────────────────

/// Find an app bundle by name. Port of `find_app_bundle` (remctl:3297).
func findAppBundle(_ appName: String?, env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    guard let appName, !appName.isEmpty else { return nil }
    let fm = FileManager.default
    let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent("Applications").appendingPathComponent(appName),
        URL(fileURLWithPath: "/Applications").appendingPathComponent(appName),
        URL(fileURLWithPath: "/System/Applications").appendingPathComponent(appName),
        URL(fileURLWithPath: "/System/Applications/Utilities").appendingPathComponent(appName),
    ]
    for c in candidates where fm.fileExists(atPath: c.path) {
        return c.resolvingSymlinksInPath()
    }
    return nil
}

/// Build the FDA target lines. Port of `full_disk_access_targets` (remctl:3373) +
/// `full_disk_access_target_specs` (remctl:3338), adapted: the "Current Python
/// interpreter" target becomes the running remctl runtime.
func fullDiskAccessTargets(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
    let context = doctorExecutionContext(env: env)
    let runtime: String = {
        if case let .string(p)? = context["python"] { return p }
        return Bundle.main.executablePath ?? "remctl"
    }()
    var specs: [(title: String, path: String)] = [("Current remctl runtime", runtime)]

    var hostApp: String? = nil
    if case let .string(h)? = context["host_app"] { hostApp = h }
    var hostPath: String? = nil
    if case let .string(p)? = context["host_app_path"] { hostPath = p }
    if hostPath == nil, let hostApp, hostApp.hasSuffix(".app") {
        hostPath = findAppBundle(hostApp, env: env)?.path
    }
    if let hostApp, let hostPath {
        specs.append((hostApp, hostPath))
    }
    if let terminalName = detectTerminalAppName(env: env) {
        // An embedded Ghostty engine inherited via TERM_PROGRAM is not the real FDA
        // target when the environment resolved a different host app (upstream aba7cf5).
        let skipTerminal = terminalName == "Ghostty.app" && hostPath != nil
            && hostApp != nil && hostApp != terminalName
        if !skipTerminal, let terminalPath = findAppBundle(terminalName, env: env) {
            specs.append((terminalName, terminalPath.path))
        }
    }

    var targets = specs.map { "\($0.title): \($0.path)" }
    if !specs.contains(where: { $0.title.hasSuffix(".app") }) {
        if let terminalName = detectTerminalAppName(env: env) {
            targets.append("\(terminalName) (recommended for CLI use)")
        } else {
            targets.append("the terminal app that is running remctl (recommended for CLI use)")
        }
    }
    return targets
}

/// Port of `full_disk_access_fix_text` (remctl:3385).
func fullDiskAccessFixText(
    rerunCommand: String = "remctl doctor",
    mentionOnboard: Bool = false,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    let targets = fullDiskAccessTargets(env: env)
    let context = doctorExecutionContext(env: env)
    let effectiveContext: String = {
        if case let .string(c)? = context["effective_context"], !c.isEmpty { return c }
        return "this runner"
    }()
    let runtime: String = {
        if case let .string(p)? = context["python"] { return p }
        return Bundle.main.executablePath ?? "remctl"
    }()
    let intro = mentionOnboard
        ? "`remctl onboard` can open a guided permission helper, but macOS still requires you to add the access target manually."
        : "Full Disk Access is missing for this process context; macOS cannot grant it from the command line."
    var parts = [
        intro,
        "Current execution context: \(effectiveContext) (\(runtime)).",
        "A green `remctl doctor` in Terminal does not grant access to a separate agent or app runner.",
        "For the guided flow, run: remctl permissions full-disk-access",
        "Open System Settings > Privacy & Security > Full Disk Access and add:",
    ]
    parts.append(contentsOf: targets.map { "  \($0)" })
    parts.append("Tip: click +, press Command-Shift-G, paste the path, press Return, then click Open.")
    parts.append("Then relaunch the app or terminal that will run remctl and rerun `\(rerunCommand)` from that same context.")
    return parts.joined(separator: "\n")
}
