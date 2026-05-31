import Foundation

// ──────────────────────────────────────────────────────────────────────────────
// onboard — the most outward-facing setup command (TCC prompts, app launch,
// System Settings). Structured as a pure-core (`Onboard.perform`) + thin-run
// (`Onboard.run`) split, mirroring Import/Add. ALL process-level side effects
// are INJECTED closures so JSON mode + tests fire NOTHING real.
//
// Source of truth: `cmd_onboard` (remctl:7471), `run_onboarding` (:3675),
// `gather_onboarding_checks` (:3664) + the 4 check builders (:3528/:3562/:3604/
// :3644), `write_onboard_state` (:3516), `needs_full_disk_access_guidance` (:3498).
//
// RE-FRAMINGS vs the Python source (intentional, documented contract change):
//   • The `eventkit` check no longer probes an external `remctl-bridge` binary;
//     EventKit is folded in-process, so it calls the injected `eventKitAuthorize`
//     seam (real: `EventKitWriter().authorize()` → calendarCount/defaultList).
//     The Python bridge-binary WARN variants ("<path> is unavailable", "did not
//     return a valid authorization response") are DROPPED — they have no analog
//     in-process. The ok / not-granted-fail paths are preserved.
//   • The `version` key in onboard-state.json is the Swift binary's own
//     `remctlVersion` (the Python `VERSION` constant has no in-process meaning).
//
// SIDE-EFFECT SEAMS (real impls supplied only by `run()`):
//   • openApp           : `open -a Reminders` + brief sleep (test: no-op recorder)
//   • eventKitAuthorize : in-process EventKit TCC prompt    (test: injected outcome)
//   • automationProbe   : osascript Automation TCC prompt   (test: injected outcome)
//   • openSettings      : /usr/bin/open of the FDA Settings URLs (Q4 seam)
//   • copyClipboard     : pbcopy of the runtime path        (Q4 seam)
//   • now               : injected clock for the state file
//   • storeAccessError / dbPath : injected store probes (like Q2 doctor probes)
//
// JSON mode runs the 4 checks (they ARE side-effecting via the seams — matching
// Python, which runs `gather_onboarding_checks` BEFORE the `--json` branch), but
// the FDA-helper / Settings / clipboard GUIDANCE is HUMAN-ONLY. JSON fires
// nothing beyond the four check seams.
// ──────────────────────────────────────────────────────────────────────────────

/// The outcome of one onboarding probe: status + detail + optional fix string.
/// The `ok` flag distinguishes the ok path from a non-ok path; for `eventkit`
/// a non-ok outcome maps to `.fail`, for `open_reminders`/`automation` it maps to
/// `.warn` (mirroring the Python per-check status semantics).
typealias OnboardProbeResult = (ok: Bool, detail: String, fix: String?)

extension Onboard {

    // ── Check builders ──────────────────────────────────────────────────────

    /// `open_reminders_app_for_onboarding` (remctl:3528). Always ok in-process —
    /// the injected `openApp` performs `open -a Reminders` + sleep; the WARN
    /// timeout/OSError variants are unreachable through the seam (the real impl
    /// best-effort-launches and never surfaces a failure), so we report ok.
    static func openRemindersCheck(openApp: () -> Void) -> DoctorCheck {
        openApp()
        return DoctorCheck(name: "open_reminders", status: .ok, detail: "Opened Reminders.app.")
    }

    /// `bridge_access_check_for_onboarding` (remctl:3562), RE-FRAMED to the
    /// in-process EventKit authorize. ok → the granted detail (referencing the
    /// remctl binary + calendarCount/defaultList, built by the real seam); not-ok
    /// → FAIL with the granted-from-same-terminal fix.
    static func eventkitCheck(_ result: OnboardProbeResult) -> DoctorCheck {
        if result.ok {
            return DoctorCheck(name: "eventkit", status: .ok, detail: result.detail)
        }
        return DoctorCheck(
            name: "eventkit",
            status: .fail,
            detail: result.detail,
            fix: result.fix
                ?? "Re-run `remctl onboard` from the same terminal and click Allow when macOS asks for Reminders access.")
    }

    /// `applescript_access_check_for_onboarding` (remctl:3604). ok → confirmed
    /// detail; not-ok → WARN with the approve-Automation fix.
    static func automationCheck(_ result: OnboardProbeResult) -> DoctorCheck {
        if result.ok {
            return DoctorCheck(name: "automation", status: .ok, detail: result.detail)
        }
        return DoctorCheck(
            name: "automation",
            status: .warn,
            detail: result.detail,
            fix: result.fix
                ?? "Re-run `remctl onboard` from the same terminal and approve the Automation prompt if macOS asks. Flagged operations and AppleScript fallback writes rely on this access.")
    }

    /// `database_access_check_for_onboarding` (remctl:3644). REUSES the
    /// `storeAccessError` / `dbPath` probes (Paths.storeAccessError /
    /// Paths.findMainDBPath in `run()`). NOTE: the FDA fix uses the
    /// `remctl doctor --for-agent` rerun command — DISTINCT by design from the
    /// printed human guidance, which uses the bare `remctl doctor`.
    static func databaseCheck(storeAccessError: String?, dbPath: String?, env: [String: String]) -> DoctorCheck {
        if let accessError = storeAccessError {
            return DoctorCheck(
                name: "database",
                status: .fail,
                detail: accessError,
                fix: fullDiskAccessFixText(rerunCommand: "remctl doctor --for-agent", mentionOnboard: false, env: env))
        }
        if let dbPath {
            return DoctorCheck(name: "database", status: .ok, detail: dbPath)
        }
        return DoctorCheck(
            name: "database",
            status: .fail,
            detail: "No Reminders database found.",
            fix: "Enable iCloud Reminders and open Reminders.app once, then rerun `remctl onboard`.")
    }

    // ── State file ────────────────────────────────────────────────────────────

    /// `write_onboard_state` (remctl:3516). mkdir CONFIG_DIR, then write the
    /// state JSON (indent=2) + trailing newline. Best-effort; failures are
    /// swallowed (the Python `mkdir(exist_ok=True)` + `write_text` never guard,
    /// but we must not crash the command if the dir is unwritable).
    static func writeOnboardState(ok: Bool, warnings: Int, failures: Int, auto: Bool,
                                  now: Date, env: [String: String]) {
        let configDir = Paths.resolveConfigDir(env: env)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let state: JSONValue = .object([
            ("version", .string(remctlVersion)),
            ("seenAt", .string(isoSeconds(now))),
            ("auto", .bool(auto)),
            ("ok", .bool(ok)),
            ("warnings", .int(warnings)),
            ("failures", .int(failures)),
        ])
        let body = state.serialized(indent: 2, ensureAscii: false) + "\n"
        let url = configDir.appendingPathComponent("onboard-state.json")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mirror Python `datetime.now().isoformat(timespec="seconds")`: a naive LOCAL
    /// "YYYY-MM-DDTHH:MM:SS" string, ALWAYS truncated to seconds (never appends
    /// fractional seconds, unlike `AppleEpoch.isoLocalNoTZ`).
    static func isoSeconds(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // ── Testable core ─────────────────────────────────────────────────────────

    /// Port of `run_onboarding(auto:false)` + `cmd_onboard` (remctl:3675/:7471).
    /// Pure of GUI/clipboard side effects when called with no-op injected seams;
    /// the ONLY real effect is the onboard-state.json write (point REMCTL_CONFIG_DIR
    /// at a temp dir in tests).
    ///
    /// Order of operations (matches Python exactly):
    ///   1. Run the 4 checks IN ORDER (open_reminders, eventkit, automation,
    ///      database) — the seams fire in BOTH json and human modes.
    ///   2. Compute ok/warnings/failures; ALWAYS write onboard-state.json.
    ///   3. JSON mode: serialize `{ok,warnings,failures,checks}` indent=2 + newline.
    ///      NOTHING else (no header, no FDA helper/Settings/clipboard).
    ///   4. Human mode: bold header + dim approve line + blank + check report;
    ///      THEN if `needsFullDiskAccessGuidance(database)` → degrade the helper
    ///      (always false) → print FDA guidance (opening Settings via the seam,
    ///      rerun `remctl doctor`).
    ///   5. Exit 1 IFF failures > 0.
    static func perform(
        auto: Bool,
        json: Bool,
        storeAccessError: String?,
        dbPath: String?,
        now: Date,
        env: [String: String],
        ansi: Ansi,
        openApp: () -> Void,
        eventKitAuthorize: () async -> OnboardProbeResult,
        automationProbe: () -> OnboardProbeResult,
        openSettings: ([String]) -> Int32,
        copyClipboard: (String) -> Bool
    ) async -> WriteOutcome {

        // 1. Four checks IN ORDER. Each seam fires here (json + human alike).
        let checks: [DoctorCheck] = [
            openRemindersCheck(openApp: openApp),
            eventkitCheck(await eventKitAuthorize()),
            automationCheck(automationProbe()),
            databaseCheck(storeAccessError: storeAccessError, dbPath: dbPath, env: env),
        ]

        let failures = checks.filter { $0.status == .fail }.count
        let warnings = checks.filter { $0.status == .warn }.count
        let ok = failures == 0

        // 2. ALWAYS write onboard-state.json.
        writeOnboardState(ok: ok, warnings: warnings, failures: failures, auto: auto, now: now, env: env)

        let exitCode: Int32 = failures > 0 ? 1 : 0

        // 3. JSON mode — serialize the result; NO human header, NO FDA guidance.
        if json {
            let result: JSONValue = .object([
                ("ok", .bool(ok)),
                ("warnings", .int(warnings)),
                ("failures", .int(failures)),
                ("checks", .array(checks.map { c in
                    .object([
                        ("name", .string(c.name)),
                        ("status", .string(c.status.rawValue)),
                        ("detail", .string(c.detail)),
                        ("fix", c.fix.map { JSONValue.string($0) } ?? .null),
                    ])
                })),
            ])
            return WriteOutcome(
                stdout: result.serialized(indent: 2, ensureAscii: false) + "\n",
                exitCode: exitCode)
        }

        // 4. Human mode — header + dim approve line + blank + check report.
        var out = ansi.bold("RemCTL onboard") + "\n"
        out += ansi.dim("Approve any macOS prompts for Reminders or Automation access.") + "\n"
        out += "\n"
        out += printCheckReport(title: nil, checks: checks, ansi: ansi) + "\n"

        // THEN: if the database check mentions Full Disk Access, fire the helper
        // (always degrades to false) → printed guidance. HUMAN-ONLY.
        let databaseCheckValue = checks.first { $0.name == "database" }
        if needsFullDiskAccessGuidance(databaseCheckValue) {
            if launchFullDiskAccessHelper(includeCli: true, wait: false) {
                out += printPermissionHelperOpened(ansi: ansi) + "\n"
            } else {
                let settingsOpened = openFullDiskAccessSettings(open: openSettings)
                out += printFullDiskAccessGuidance(
                    settingsOpened: settingsOpened,
                    rerunCommand: "remctl doctor",
                    ansi: ansi,
                    env: env,
                    runPbcopy: copyClipboard) + "\n"
            }
        }

        return WriteOutcome(stdout: out, exitCode: exitCode)
    }
}
