import Foundation

// ──────────────────────────────────────────────────────────────────────────────
// Full Disk Access helper family
//
// Source of truth: `full_disk_access_target_specs` (remctl:3338),
// `full_disk_access_targets` (remctl:3373), `full_disk_access_fix_text` (:3385),
// `open_full_disk_access_settings` (:3420), `copy_to_clipboard` (: ~3406),
// `print_full_disk_access_guidance` (:3436), `print_permission_helper_opened`
// (:3490), `needs_full_disk_access_guidance` (:3498),
// `permission_helper_available` (:3458), `launch_full_disk_access_helper` (:3463),
// `current_permissions_path` (:7025), `cmd_permissions` (:7494).
//
// CONSOLIDATION: `full_disk_access_targets`, `full_disk_access_fix_text`,
// `find_app_bundle`, and the execution-context helpers already live in
// DoctorSupport.swift (ported as part of Q2). This file adds the DISTINCT
// helpers needed by Q4 — notably `fullDiskAccessTargetSpecs` (the dict-list
// for JSON, structurally different from the string-list `fullDiskAccessTargets`)
// and the side-effecting `open`/`pbcopy`/guidance functions — all behind
// INJECTED seams so JSON mode and tests produce no real GUI/clipboard effects.
//
// LOCKED DECISION (graceful-degrade, no AppKit GUI):
//   `permissionHelperAvailable()` → always `false`.
//   `launchFullDiskAccessHelper(includeCli:wait:)` → always `false`.
// Consequence: both `permissions` and `onboard` deterministically take the
// printed-guidance branch (open System Settings via /usr/bin/open + print
// guidance). `permissions --json` emits `"available": false`. Documented as an
// intentional contract divergence for the single-binary reality (no bundled
// remctl-permissions AppKit helper). See recon finding "onboard+permissions".
// ──────────────────────────────────────────────────────────────────────────────

/// URLs tried in order to open the Full Disk Access settings pane.
/// Port of `FULL_DISK_ACCESS_SETTINGS_URLS` (remctl:58).
let fullDiskAccessSettingsURLs = [
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
]

// ──────────────────────────────────────────────────────────────────────────────
// Target specs — the DICT-LIST variant for JSON / helper args.
// Distinct from `fullDiskAccessTargets()` (string list for guidance text).
// ──────────────────────────────────────────────────────────────────────────────

/// Port of `_add_permission_target` (remctl:3327): dedup by lowercased resolved path.
private func addPermissionTarget(
    _ targets: inout [[(String, JSONValue)]],
    seen: inout Set<String>,
    title: String,
    path rawPath: String,
    subtitle: String
) {
    guard !rawPath.isEmpty else { return }
    let resolved = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        .resolvingSymlinksInPath().path
    let key = resolved.lowercased()
    guard !seen.contains(key) else { return }
    seen.insert(key)
    targets.append([
        ("title", .string(title)),
        ("path", .string(resolved)),
        ("subtitle", .string(subtitle)),
    ])
}

/// Port of `full_disk_access_target_specs(include_cli=True)` (remctl:3338).
/// Returns a dict list `[{title, path, subtitle}]` deduplicated by lowercased
/// resolved path. The Python "Current Python interpreter" target → the remctl
/// runtime binary + an equivalent subtitle.
///
/// Distinct from `fullDiskAccessTargets()` (DoctorSupport.swift), which returns
/// a string list for human guidance text and synthesises an extra terminal line.
func fullDiskAccessTargetSpecs(
    includeCli: Bool,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [[(String, JSONValue)]] {
    var targets: [[(String, JSONValue)]] = []
    var seen = Set<String>()

    if includeCli {
        let context = doctorExecutionContext(env: env)
        let runtime: String = {
            if case let .string(p)? = context["python"] { return p }
            return Bundle.main.executablePath ?? "remctl"
        }()
        addPermissionTarget(
            &targets, seen: &seen,
            title: "Current remctl runtime",
            path: runtime,
            subtitle: "Required when direct CLI reads cannot see the Reminders database."
        )

        if case let .string(hostApp)? = context["host_app"],
           hostApp.hasSuffix(".app"),
           let hostPath = findAppBundle(hostApp, env: env) {
            addPermissionTarget(
                &targets, seen: &seen,
                title: hostApp,
                path: hostPath.path,
                subtitle: "Required when this host app launches remctl or an agent runner."
            )
        }

        if let terminalName = detectTerminalAppName(env: env),
           let terminalPath = findAppBundle(terminalName, env: env) {
            addPermissionTarget(
                &targets, seen: &seen,
                title: terminalName,
                path: terminalPath.path,
                subtitle: "Alternative target for direct CLI reads from this terminal app."
            )
        }
    }
    return targets
}

// ──────────────────────────────────────────────────────────────────────────────
// Helper availability — hardcoded false (no bundled remctl-permissions binary).
// ──────────────────────────────────────────────────────────────────────────────

/// Port of `current_permissions_path` (remctl:7025): the path where a sibling
/// `remctl-permissions` binary *would* reside. Since no helper is bundled in
/// the single-binary Swift port, this path will not exist.
func currentPermissionsPath(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    // Honor REMCTL_PERMISSIONS_PATH env override (for testing or future use).
    if let v = env["REMCTL_PERMISSIONS_PATH"], !v.isEmpty {
        return (v as NSString).expandingTildeInPath
    }
    // Fall back to the sibling-binary convention: same directory as the CLI.
    let cli = currentCLIPath(env: env)
    return cli.deletingLastPathComponent().appendingPathComponent("remctl-permissions").path
}

/// `permission_helper_available` (remctl:3458) — HARDCODED `false`.
///
/// The single-binary Swift port does NOT bundle the AppKit GUI helper
/// (`remctl-permissions.swift`). Porting it in-process would force the CLI
/// to link AppKit and become an NSApplication, breaking every headless/CI
/// context. The printed-guidance fallback is the contract-defined path that
/// all non-interactive callers hit regardless. Therefore, this function is
/// unconditionally false and both `permissions` and `onboard` deterministically
/// take the guidance branch. See Phase-4 recon, "onboard+permissions" finding.
func permissionHelperAvailable() -> Bool { false }

/// `launch_full_disk_access_helper` (remctl:3463) — always returns `false`.
///
/// No helper binary is bundled, so the caller always falls through to
/// `openFullDiskAccessSettings` + `printFullDiskAccessGuidance`.
func launchFullDiskAccessHelper(includeCli: Bool, wait: Bool) -> Bool { false }

// ──────────────────────────────────────────────────────────────────────────────
// Side-effecting helpers — injected seams so tests record calls without firing.
// ──────────────────────────────────────────────────────────────────────────────

/// Port of `open_full_disk_access_settings` (remctl:3420).
///
/// Tries each URL in `fullDiskAccessSettingsURLs` via the injected `open`
/// closure (default: `/usr/bin/open`). Returns `true` on first success (rc=0).
/// The `open` closure receives `[url]` and returns the process exit code;
/// the default real implementation uses `/usr/bin/open` (AppKit-free, matching
/// the Python `subprocess.run(["open", url], ...)` mechanism exactly).
@discardableResult
func openFullDiskAccessSettings(
    open runOpen: ([String]) -> Int32 = { args in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return 1
        }
    }
) -> Bool {
    for url in fullDiskAccessSettingsURLs {
        if runOpen([url]) == 0 { return true }
    }
    return false
}

/// Port of `copy_to_clipboard` (remctl: ~3406).
///
/// Pipes `text` into `pbcopy` via the injected `run` closure (default: real
/// subprocess). Returns `true` on success (rc=0). Failures are silently
/// swallowed (matching Python's `except (OSError, TimeoutExpired): return False`).
@discardableResult
func copyToClipboard(
    _ text: String,
    run runPbcopy: (String) -> Bool = { text in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        proc.standardInput = pipe
        do {
            try proc.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
) -> Bool {
    return runPbcopy(text)
}

// ──────────────────────────────────────────────────────────────────────────────
// Printed output helpers — return String so callers control print/stdout.
// ──────────────────────────────────────────────────────────────────────────────

/// Port of `print_permission_helper_opened` (remctl:3490).
/// Returns the 4-line Guided Full Disk Access block (blank line + 3 dim lines).
/// The command prints this via `print(...)`.
func printPermissionHelperOpened(ansi: Ansi = Ansi(enabled: false)) -> String {
    let a = ansi
    return [
        "",
        a.bold("Guided Full Disk Access"),
        a.dim("  Opened the RemCTL permission helper."),
        a.dim("  It opens System Settings, copies the first target path, and provides draggable targets."),
        a.dim("  In the file picker, press Command-Shift-G if drag-and-drop is not accepted."),
    ].joined(separator: "\n")
}

/// Port of `print_full_disk_access_guidance` (remctl:3436).
///
/// Returns the full guidance block as a String. Side effects (open Settings,
/// copy to clipboard) are INJECTED:
///   - `open`: called to open System Settings URLs (receives url list, returns exit code)
///   - `runPbcopy`: called to copy a path to the clipboard (receives text, returns success)
///
/// In JSON mode the command DOES NOT CALL THIS — it exits after serializing.
/// In human mode the command calls this after `launchFullDiskAccessHelper` returns false.
func printFullDiskAccessGuidance(
    settingsOpened: Bool,
    rerunCommand: String = "remctl doctor",
    ansi: Ansi = Ansi(enabled: false),
    env: [String: String] = ProcessInfo.processInfo.environment,
    runPbcopy: (String) -> Bool = { text in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        proc.standardInput = pipe
        do {
            try proc.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch { return false }
    }
) -> String {
    let a = ansi
    let context = doctorExecutionContext(env: env)
    let effectiveCtx: String = {
        if case let .string(c)? = context["effective_context"], !c.isEmpty { return c }
        return "unknown"
    }()
    let runtime: String = {
        if case let .string(p)? = context["python"] { return p }
        return Bundle.main.executablePath ?? "remctl"
    }()

    // Copy the runtime path to clipboard; record success.
    let copied = copyToClipboard(runtime, run: runPbcopy)

    var lines: [String] = [
        "",
        a.bold("Full Disk Access"),
    ]
    if settingsOpened {
        lines.append(a.dim("  Opened System Settings > Privacy & Security > Full Disk Access."))
    } else {
        lines.append(a.dim("  Open System Settings > Privacy & Security > Full Disk Access."))
    }
    lines.append(a.dim("  macOS requires you to add the access target manually for this process context."))
    lines.append(a.dim("  Current context: \(effectiveCtx) (\(runtime))"))

    let targets = fullDiskAccessTargets(env: env)
    for target in targets {
        lines.append(a.dim("  Add: \(target)"))
    }

    if copied {
        lines.append(a.dim("  Copied path to clipboard: \(runtime)"))
    } else {
        lines.append(a.dim("  Copy this path if you need the file picker: \(runtime)"))
    }
    lines.append(a.dim("  In the file picker, press Command-Shift-G, paste the path, press Return, then click Open."))
    lines.append(a.dim("  Then relaunch the app or terminal that will run remctl and rerun `\(rerunCommand)`."))

    return lines.joined(separator: "\n")
}

// ──────────────────────────────────────────────────────────────────────────────
// needs_full_disk_access_guidance (remctl:3498)
// ──────────────────────────────────────────────────────────────────────────────

/// Port of `needs_full_disk_access_guidance(check)` (remctl:3498).
/// Returns `true` if the check's `fix` OR `detail` contains "Full Disk Access".
/// Used by `onboard` (human mode) to decide whether to fire the helper/guidance.
func needsFullDiskAccessGuidance(_ check: DoctorCheck?) -> Bool {
    guard let check else { return false }
    return (check.fix ?? "").contains("Full Disk Access")
        || check.detail.contains("Full Disk Access")
}
