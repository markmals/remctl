import Testing
import Foundation
import EventKit
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// DoctorTests — drive the pure CI seam `gatherDoctorChecks(probes:)` with injected
// fixtures, plus the result/report renderers. Re-framed in-process contract:
//   checks (in order): platform, macos, store_dir, database, cli, eventkit,
//                      reminderkit, config_dir, completion
//   • macos (was python), eventkit (was bridge), reminderkit (was private_helper)
//     are RE-FRAMED; permissions_helper is DROPPED.
//   • eventkit + reminderkit are always WARN (never FAIL) → exit-code parity.
//   • doctor exits 1 IFF fail_count > 0.
//
// The execution-context probe (ps ancestry / TERM_PROGRAM) and live EventKit/RKP
// reads are environment-coupled: tests assert SHAPE/keys only, never live values.
// ──────────────────────────────────────────────────────────────────────────────

/// All-ok fixture probes. Mutate fields per scenario.
private func okProbes() -> DoctorProbes {
    DoctorProbes(
        isDarwin: true,
        platformDetail: "macOS 15.5",
        macOSDetail: "macOS 15.5",
        storeDirPath: "/tmp/store",
        storeDirExists: true,
        storeAccessError: nil,
        dbPath: "/tmp/store/Data-1.sqlite",
        cliPath: "/usr/local/bin/remctl",
        cliExists: true,
        cliOnPath: true,
        eventKitAuthStatus: .fullAccess,
        reminderKitProbeResult: "reminderkit-ok",
        configDirPath: "/home/test/.config/remctl",
        configDirExists: true,
        shellName: "zsh",
        completionTargetPath: "/home/test/.zsh/completions/_remctl",
        completionTargetExists: true,
        fullDiskAccessFixText: { "FDA-FIX-TEXT\nsecond line" })
}

private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
    checks.first { $0.name == name }
}

// MARK: - All-ok

@Suite struct DoctorAllOkTests {

    @Test("all-ok probes → every check ok, exit 0")
    func allOk() {
        let checks = gatherDoctorChecks(probes: okProbes())
        #expect(checks.allSatisfy { $0.status == .ok })
        let (_, fail, warn) = DoctorRuntime.buildResult(checks: checks, context: [:], forAgent: false)
        #expect(fail == 0)
        #expect(warn == 0)
    }

    @Test("check order + names are the re-framed contract")
    func orderAndNames() {
        let names = gatherDoctorChecks(probes: okProbes()).map { $0.name }
        #expect(names == ["platform", "macos", "store_dir", "database", "cli",
                          "eventkit", "reminderkit", "config_dir", "completion"])
    }

    @Test("no check is named python / bridge / private_helper / permissions_helper")
    func droppedAndRenamedNamesAbsent() {
        let names = Set(gatherDoctorChecks(probes: okProbes()).map { $0.name })
        #expect(!names.contains("python"))
        #expect(!names.contains("bridge"))
        #expect(!names.contains("private_helper"))
        #expect(!names.contains("permissions_helper"))
    }
}

// MARK: - platform

@Suite struct DoctorPlatformTests {

    @Test("non-darwin → platform FAIL with macOS-only fix")
    func nonDarwinFails() {
        var p = okProbes(); p.isDarwin = false
        let checks = gatherDoctorChecks(probes: p)
        let platform = check(checks, "platform")
        #expect(platform?.status == .fail)
        #expect(platform?.fix == "RemCTL only supports macOS.")
    }

    @Test("macos check is always ok (re-framed from python)")
    func macosAlwaysOk() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let macos = check(checks, "macos")
        #expect(macos?.status == .ok)
        #expect(macos?.fix == nil)
        #expect(macos?.detail == "macOS 15.5")
    }
}

// MARK: - store_dir / database

@Suite struct DoctorDatabaseTests {

    @Test("store dir missing → store_dir FAIL")
    func storeDirMissing() {
        var p = okProbes(); p.storeDirExists = false
        let checks = gatherDoctorChecks(probes: p)
        #expect(check(checks, "store_dir")?.status == .fail)
        #expect(check(checks, "store_dir")?.fix == "Set REMCTL_STORE_DIR if your Reminders store lives elsewhere.")
    }

    @Test("store-access-error → database FAIL with FDA fix text, exit 1")
    func storeAccessErrorFails() {
        var p = okProbes()
        p.storeAccessError = "Direct CLI reads are blocked ..."
        let checks = gatherDoctorChecks(probes: p)
        let db = check(checks, "database")
        #expect(db?.status == .fail)
        #expect(db?.detail == "Direct CLI reads are blocked ...")
        #expect(db?.fix == "FDA-FIX-TEXT\nsecond line")
        let (_, fail, _) = DoctorRuntime.buildResult(checks: checks, context: [:], forAgent: false)
        #expect(fail == 1)
    }

    @Test("no database file (no access error) → database FAIL with onboard fix")
    func noDatabaseFails() {
        var p = okProbes(); p.dbPath = nil
        let checks = gatherDoctorChecks(probes: p)
        let db = check(checks, "database")
        #expect(db?.status == .fail)
        #expect(db?.detail == "No Reminders database found")
        #expect(db?.fix == "Enable iCloud Reminders and open Reminders.app once, or run remctl onboard.")
    }

    @Test("database ok → detail is the db path, no fix")
    func databaseOk() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let db = check(checks, "database")
        #expect(db?.status == .ok)
        #expect(db?.detail == "/tmp/store/Data-1.sqlite")
        #expect(db?.fix == nil)
    }
}

// MARK: - cli quirk

@Suite struct DoctorCliTests {

    @Test("cli present but NOT on PATH → status ok (exists) WITH a PATH fix (quirk)")
    func cliNotOnPathQuirk() {
        var p = okProbes()
        p.cliExists = true
        p.cliOnPath = false
        p.cliPath = "/opt/tools/remctl"
        let checks = gatherDoctorChecks(probes: p)
        let cli = check(checks, "cli")
        #expect(cli?.status == .ok)       // status keys off EXISTENCE
        #expect(cli?.fix == "Add /opt/tools to PATH.")  // fix keys off PATH-presence
    }

    @Test("cli on PATH → ok with no fix")
    func cliOnPathNoFix() {
        let cli = check(gatherDoctorChecks(probes: okProbes()), "cli")
        #expect(cli?.status == .ok)
        #expect(cli?.fix == nil)
    }

    @Test("cli missing → FAIL")
    func cliMissingFails() {
        var p = okProbes(); p.cliExists = false; p.cliOnPath = false
        #expect(check(gatherDoctorChecks(probes: p), "cli")?.status == .fail)
    }
}

// MARK: - eventkit (re-framed bridge), always WARN never FAIL

@Suite struct DoctorEventKitTests {

    @Test(".fullAccess → eventkit ok")
    func fullAccessOk() {
        var p = okProbes(); p.eventKitAuthStatus = .fullAccess
        let ek = check(gatherDoctorChecks(probes: p), "eventkit")
        #expect(ek?.status == .ok)
        #expect(ek?.fix == nil)
    }

    @Test("legacy .authorized (rawValue 3) → eventkit ok")
    func legacyAuthorizedOk() {
        var p = okProbes()
        // rawValue 3 is the legacy `.authorized` (renamed to `.fullAccess`).
        p.eventKitAuthStatus = EKAuthorizationStatus(rawValue: 3)!
        let ek = check(gatherDoctorChecks(probes: p), "eventkit")
        #expect(ek?.status == .ok)
    }

    @Test(".denied → eventkit WARN (NOT fail), still exit 0")
    func deniedWarns() {
        var p = okProbes(); p.eventKitAuthStatus = .denied
        let checks = gatherDoctorChecks(probes: p)
        let ek = check(checks, "eventkit")
        #expect(ek?.status == .warn)
        #expect(ek?.fix?.contains("remctl onboard") == true)
        let (_, fail, _) = DoctorRuntime.buildResult(checks: checks, context: [:], forAgent: false)
        #expect(fail == 0)  // parity: warn never fails
    }

    @Test(".notDetermined → eventkit WARN")
    func notDeterminedWarns() {
        var p = okProbes(); p.eventKitAuthStatus = .notDetermined
        #expect(check(gatherDoctorChecks(probes: p), "eventkit")?.status == .warn)
    }
}

// MARK: - reminderkit (re-framed private_helper), always WARN never FAIL

@Suite struct DoctorReminderKitTests {

    @Test("reminderkit-ok → reminderkit ok")
    func probeOk() {
        let rk = check(gatherDoctorChecks(probes: okProbes()), "reminderkit")
        #expect(rk?.status == .ok)
        #expect(rk?.detail == "reminderkit-ok")
        #expect(rk?.fix == nil)
    }

    @Test("reminderkit-missing → reminderkit WARN, still exit 0")
    func probeMissingWarns() {
        var p = okProbes(); p.reminderKitProbeResult = "reminderkit-missing"
        let checks = gatherDoctorChecks(probes: p)
        let rk = check(checks, "reminderkit")
        #expect(rk?.status == .warn)
        #expect(rk?.detail == "reminderkit-missing")
        #expect(rk?.fix?.contains("--private") == true)
        let (_, fail, _) = DoctorRuntime.buildResult(checks: checks, context: [:], forAgent: false)
        #expect(fail == 0)
    }
}

// MARK: - config_dir / completion

@Suite struct DoctorConfigCompletionTests {

    @Test("config dir missing → config_dir WARN + setup fix")
    func configDirMissingWarns() {
        var p = okProbes(); p.configDirExists = false
        let c = check(gatherDoctorChecks(probes: p), "config_dir")
        #expect(c?.status == .warn)
        #expect(c?.fix == "Run remctl setup to create config files.")
    }

    @Test("completion not installed (supported shell) → WARN + shell-specific fix")
    func completionMissingWarns() {
        var p = okProbes(); p.completionTargetExists = false
        let c = check(gatherDoctorChecks(probes: p), "completion")
        #expect(c?.status == .warn)
        #expect(c?.detail == "zsh: /home/test/.zsh/completions/_remctl")
        #expect(c?.fix == "Run remctl setup --shell zsh to install completion.")
    }

    @Test("completion installed → ok")
    func completionInstalledOk() {
        let c = check(gatherDoctorChecks(probes: okProbes()), "completion")
        #expect(c?.status == .ok)
        #expect(c?.fix == nil)
    }

    @Test("unsupported shell → completion WARN with unsupported-shell branch")
    func unsupportedShellWarns() {
        var p = okProbes()
        p.shellName = "tcsh"
        p.completionTargetPath = nil
        p.completionTargetExists = false
        let c = check(gatherDoctorChecks(probes: p), "completion")
        #expect(c?.status == .warn)
        #expect(c?.detail == "Unsupported shell 'tcsh'")
        #expect(c?.fix == "Run remctl setup --shell zsh|bash|fish.")
    }
}

// MARK: - buildResult JSON shape

@Suite struct DoctorResultShapeTests {

    private func sampleContext() -> [String: JSONValue] {
        [
            "python": .string("/usr/local/bin/remctl"),
            "pid": .int(123),
            "parent_process": .null,
            "terminal_app": .null,
            "host_app": .null,
            "effective_context": .string("unknown"),
        ]
    }

    @Test("result has keys ok/warnings/failures/context/checks in order")
    func resultKeys() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let (result, _, _) = DoctorRuntime.buildResult(checks: checks, context: sampleContext(), forAgent: false)
        guard case let .object(pairs) = result else { Issue.record("result not an object"); return }
        #expect(pairs.map { $0.0 } == ["ok", "warnings", "failures", "context", "checks"])
    }

    @Test("--for-agent adds agent_note key with verbatim text")
    func forAgentAddsNote() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let (result, _, _) = DoctorRuntime.buildResult(checks: checks, context: sampleContext(), forAgent: true)
        guard case let .object(pairs) = result else { Issue.record("result not an object"); return }
        #expect(pairs.map { $0.0 } == ["ok", "warnings", "failures", "context", "checks", "agent_note"])
        let dict = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        #expect(dict["agent_note"] == .string(DoctorRuntime.agentNoteJSON))
    }

    @Test("without --for-agent there is no agent_note key")
    func noAgentNoteByDefault() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let (result, _, _) = DoctorRuntime.buildResult(checks: checks, context: sampleContext(), forAgent: false)
        guard case let .object(pairs) = result else { Issue.record("result not an object"); return }
        #expect(!pairs.contains { $0.0 == "agent_note" })
    }

    @Test("ok=false when any check fails")
    func okFalseOnFail() {
        var p = okProbes(); p.storeDirExists = false
        let checks = gatherDoctorChecks(probes: p)
        let (result, fail, _) = DoctorRuntime.buildResult(checks: checks, context: sampleContext(), forAgent: false)
        let dict = { () -> [String: JSONValue] in
            guard case let .object(pairs) = result else { return [:] }
            return Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        }()
        #expect(dict["ok"] == .bool(false))
        #expect(fail >= 1)
    }

    @Test("each check serializes with name/status/detail/fix keys, indent=2")
    func checkSerializationShape() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let (result, _, _) = DoctorRuntime.buildResult(checks: checks, context: sampleContext(), forAgent: false)
        let json = result.serialized(indent: 2, ensureAscii: false)
        // indent=2 → newline-and-spaces formatting present.
        #expect(json.contains("\n  \"ok\": true"))
        #expect(json.contains("\"name\": \"platform\""))
        #expect(json.contains("\"status\": \"ok\""))
        #expect(json.contains("\"detail\":"))
        #expect(json.contains("\"fix\":"))
    }
}

// MARK: - printCheckReport formatting (ansi disabled)

@Suite struct DoctorReportFormatTests {

    private let plain = Ansi(enabled: false)

    @Test("label + name + detail line format")
    func lineFormat() {
        let checks = [DoctorCheck(name: "platform", status: .ok, detail: "macOS 15.5", fix: nil)]
        let report = printCheckReport(title: nil, checks: checks, ansi: plain)
        #expect(report.contains("[OK] platform: macOS 15.5"))
    }

    @Test("WARN and FAIL labels render")
    func warnFailLabels() {
        let checks = [
            DoctorCheck(name: "a", status: .warn, detail: "w", fix: nil),
            DoctorCheck(name: "b", status: .fail, detail: "f", fix: nil),
        ]
        let report = printCheckReport(title: nil, checks: checks, ansi: plain)
        #expect(report.contains("[WARN] a: w"))
        #expect(report.contains("[FAIL] b: f"))
    }

    @Test("fix lines are indented 6 spaces, one per source line")
    func fixIndentation() {
        let checks = [DoctorCheck(name: "x", status: .fail, detail: "d", fix: "line one\nline two")]
        let report = printCheckReport(title: nil, checks: checks, ansi: plain)
        let lines = report.components(separatedBy: "\n")
        #expect(lines.contains("      line one"))
        #expect(lines.contains("      line two"))
    }

    @Test("summary pluralizes: 1 warning singular, 0/2 failures plural")
    func summaryPluralization() {
        let oneWarn = [DoctorCheck(name: "a", status: .warn, detail: "x", fix: nil)]
        let r1 = printCheckReport(title: nil, checks: oneWarn, ansi: plain)
        #expect(r1.contains("1 checks, 1 warning, 0 failures"))

        let twoFail = [
            DoctorCheck(name: "a", status: .fail, detail: "x", fix: nil),
            DoctorCheck(name: "b", status: .fail, detail: "y", fix: nil),
        ]
        let r2 = printCheckReport(title: nil, checks: twoFail, ansi: plain)
        #expect(r2.contains("2 checks, 0 warnings, 2 failures"))
    }

    @Test("all-ok summary uses 'warnings'/'failures' plural with zero counts")
    func allOkSummary() {
        let checks = gatherDoctorChecks(probes: okProbes())
        let report = printCheckReport(title: nil, checks: checks, ansi: plain)
        #expect(report.contains("9 checks, 0 warnings, 0 failures"))
    }

    @Test("title line renders when provided")
    func titleRenders() {
        let report = printCheckReport(title: "Hello", checks: [], ansi: plain)
        #expect(report.hasPrefix("Hello\n"))
    }
}

// MARK: - doctorExecutionContext SHAPE (degrade-only; no live-value assertions)

@Suite struct DoctorExecutionContextTests {

    @Test("context returns the expected keys (values may be unknown/null)")
    func contextKeys() {
        let ctx = doctorExecutionContext()
        for key in ["python", "pid", "parent_process", "terminal_app", "host_app", "effective_context"] {
            #expect(ctx[key] != nil, "missing key \(key)")
        }
    }

    @Test("effective_context is a non-empty string (degrades to 'unknown')")
    func effectiveContextIsString() {
        let ctx = doctorExecutionContext()
        if case let .string(v)? = ctx["effective_context"] {
            #expect(!v.isEmpty)
        } else {
            Issue.record("effective_context not a string")
        }
    }

    @Test("pid is an int")
    func pidIsInt() {
        if case .int = doctorExecutionContext()["pid"] {} else {
            Issue.record("pid not an int")
        }
    }
}

// MARK: - eventKitStatusDescription helper

@Suite struct EventKitStatusDescriptionTests {
    @Test("descriptions are distinct, non-empty strings")
    func descriptions() {
        let statuses: [EKAuthorizationStatus] = [.notDetermined, .restricted, .denied, .fullAccess, .writeOnly]
        let descs = statuses.map { eventKitStatusDescription($0) }
        #expect(descs.allSatisfy { !$0.isEmpty })
        #expect(Set(descs).count == descs.count)
    }
}

// MARK: - Command-level integration via CLIRunner (real binary, env overrides)

@Suite struct DoctorCLITests {

    /// Bogus store dir → store_dir + database FAIL → exit 1.
    @Test("doctor exits 1 when store dir is missing")
    func exitsOneOnFailure() throws {
        let bogus = URL(fileURLWithPath: "/tmp/remctl-doctor-missing-\(UUID().uuidString)")
        let result = try CLIRunner.run(["doctor"], storeDir: bogus)
        #expect(result.exit == 1)
        #expect(result.stdout.contains("RemCTL doctor"))
        #expect(result.stdout.contains("[FAIL] store_dir:"))
    }

    /// A readable store dir with a Data-*.sqlite → only warnings (eventkit/config/completion)
    /// → exit 0 (warn-never-fails parity). HOME/CONFIG_DIR are redirected to temp dirs.
    @Test("doctor exits 0 when only warnings (eventkit/config/completion)")
    func exitsZeroWithOnlyWarnings() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-doctor-\(UUID().uuidString)")
        let store = tmp.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.appendingPathComponent("Data-1.sqlite").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try CLIRunner.run(
            ["doctor"], storeDir: store,
            extraEnv: ["HOME": tmp.path, "REMCTL_CONFIG_DIR": tmp.appendingPathComponent("config").path])
        #expect(result.exit == 0)
        #expect(result.stdout.contains("[OK] store_dir:"))
        #expect(result.stdout.contains("[OK] database:"))
    }

    @Test("doctor --json emits ok/warnings/failures/context/checks with indent=2")
    func jsonShape() throws {
        let bogus = URL(fileURLWithPath: "/tmp/remctl-doctor-missing-\(UUID().uuidString)")
        let result = try CLIRunner.run(["doctor", "--json"], storeDir: bogus)
        // --json never adds agent_note unless --for-agent; exit still reflects fails.
        #expect(result.exit == 1)
        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["ok"] as? Bool == false)
        #expect(obj?["warnings"] != nil)
        #expect(obj?["failures"] != nil)
        #expect(obj?["context"] != nil)
        #expect(obj?["checks"] != nil)
        #expect(obj?["agent_note"] == nil)
        // indent=2 → pretty-printed (contains the 2-space-indented first key).
        #expect(result.stdout.contains("\n  \"ok\":"))
    }

    @Test("doctor --for-agent --json adds agent_note")
    func forAgentJSON() throws {
        let bogus = URL(fileURLWithPath: "/tmp/remctl-doctor-missing-\(UUID().uuidString)")
        let result = try CLIRunner.run(["doctor", "--for-agent", "--json"], storeDir: bogus)
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect((obj?["agent_note"] as? String)?.contains("process context") == true)
    }

    @Test("doctor --for-agent human prints the Agent note line")
    func forAgentHuman() throws {
        let bogus = URL(fileURLWithPath: "/tmp/remctl-doctor-missing-\(UUID().uuidString)")
        let result = try CLIRunner.run(["doctor", "--for-agent"], storeDir: bogus)
        #expect(result.stdout.contains("Agent note: `doctor` must pass in the same context"))
    }
}

// MARK: - completion_fpath (port upstream aba7cf5)

@Suite struct DoctorFpathTests {
    private func zshProbes(loadable: Bool?) -> DoctorProbes {
        DoctorProbes(
            isDarwin: true, platformDetail: "macOS 15.5", macOSDetail: "macOS 15.5",
            storeDirPath: "/tmp/store", storeDirExists: true, storeAccessError: nil,
            dbPath: "/tmp/store/Data-1.sqlite",
            cliPath: "/usr/local/bin/remctl", cliExists: true, cliOnPath: true,
            eventKitAuthStatus: .fullAccess, reminderKitProbeResult: "reminderkit-ok",
            configDirPath: "/home/test/.config/remctl", configDirExists: true,
            shellName: "zsh",
            completionTargetPath: "/home/test/.zsh/completions/_remctl",
            completionTargetExists: true,
            completionFpathLoadable: loadable,
            fullDiskAccessFixText: { "FDA" })
    }

    @Test func loadableEmitsOk() {
        let checks = gatherDoctorChecks(probes: zshProbes(loadable: true))
        let c = checks.first { $0.name == "completion_fpath" }
        #expect(c?.status == .ok)
        #expect(c?.detail == "/home/test/.zsh/completions is on zsh fpath")
        #expect(c?.fix == nil)
    }

    @Test func notLoadableWarnsWithHint() {
        let checks = gatherDoctorChecks(probes: zshProbes(loadable: false))
        let c = checks.first { $0.name == "completion_fpath" }
        #expect(c?.status == .warn)
        #expect(c?.detail == "/home/test/.zsh/completions is not on zsh fpath")
        #expect(c?.fix?.contains("fpath=(/home/test/.zsh/completions $fpath)") == true)
        #expect(c?.fix?.contains("autoload -Uz compinit && compinit") == true)
    }

    @Test func notApplicableEmitsNoCheck() {
        let checks = gatherDoctorChecks(probes: zshProbes(loadable: nil))
        #expect(!checks.contains { $0.name == "completion_fpath" })
    }

    @Test func fpathCheckFollowsCompletionCheck() {
        let names = gatherDoctorChecks(probes: zshProbes(loadable: true)).map(\.name)
        let ci = names.firstIndex(of: "completion")
        let fi = names.firstIndex(of: "completion_fpath")
        #expect(ci != nil && fi != nil && fi == ci.map { $0 + 1 })
    }
}

// MARK: - zshCompletionLoadable (port upstream aba7cf5)

@Suite struct ZshCompletionLoadableTests {
    private func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-zshrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func trueWhenDirOnExportedFPATH() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let completions = home.appendingPathComponent(".zsh/completions")
        let path = completions.appendingPathComponent("_remctl")
        let env = ["FPATH": "/usr/share/zsh:\(completions.path)", "HOME": home.path]
        #expect(zshCompletionLoadable(path, env: env))
    }

    @Test func trueWhenZshrcMentionsDir() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let completions = home.appendingPathComponent(".zsh/completions")
        let path = completions.appendingPathComponent("_remctl")
        try "fpath=(\(completions.path) $fpath)\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        #expect(zshCompletionLoadable(path, env: ["HOME": home.path]))
    }

    @Test func trueWhenZshrcMentionsTildeRelative() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let completions = home.appendingPathComponent(".zsh/completions")
        let path = completions.appendingPathComponent("_remctl")
        try "fpath=(~/.zsh/completions $fpath)\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        #expect(zshCompletionLoadable(path, env: ["HOME": home.path]))
    }

    @Test func honorsZDOTDIR() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let zdot = home.appendingPathComponent("zdot")
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        let completions = home.appendingPathComponent(".zsh/completions")
        let path = completions.appendingPathComponent("_remctl")
        try "fpath=(\(completions.path) $fpath)\n".write(
            to: zdot.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        #expect(zshCompletionLoadable(path, env: ["HOME": home.path, "ZDOTDIR": zdot.path]))
    }

    @Test func falseWhenNowhere() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".zsh/completions/_remctl")
        #expect(!zshCompletionLoadable(path, env: ["HOME": home.path]))
    }
}

// MARK: - Host-app bundle context (port upstream aba7cf5)

@Suite struct BundleContextTests {
    /// Make a real `<name>.app` directory under a temp root; returns (root, bundleURL).
    private func makeAppBundle(_ name: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-bundle-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        return (root, bundle)
    }

    @Test func pathHintExtractsExistingBundle() throws {
        let (root, bundle) = try makeAppBundle("Ghostty.app")
        defer { try? FileManager.default.removeItem(at: root) }
        let hint = bundle.appendingPathComponent("Contents/Resources").path
        #expect(appBundleFromPathHint(hint)?.lastPathComponent == "Ghostty.app")
        #expect(appBundleFromPathHint("/nonexistent/Nope.app/Contents") == nil)
        #expect(appBundleFromPathHint(nil) == nil)
        #expect(appBundleFromPathHint("no app here") == nil)
    }

    @Test func bundleContextPrefersCFBundleIdentifier() throws {
        let (root, bundle) = try makeAppBundle("Cursor.app")
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = bundleContextFromEnvironment(
            env: ["__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"],
            bundleResolver: { _ in bundle })
        #expect(ctx?.app == "Cursor.app")
        #expect(ctx?.path == bundle.path)
        #expect(ctx?.source == "__CFBundleIdentifier")
        #expect(ctx?.bundleId == "com.todesktop.230313mzl4w4u92")
    }

    @Test func bundleContextFallsBackToGhosttyEnv() throws {
        let (root, bundle) = try makeAppBundle("Ghostty.app")
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = bundleContextFromEnvironment(
            env: ["GHOSTTY_RESOURCES_DIR": bundle.appendingPathComponent("Contents/Resources").path],
            bundleResolver: { _ in nil })
        #expect(ctx?.app == "Ghostty.app")
        #expect(ctx?.source == "GHOSTTY_RESOURCES_DIR")
    }

    @Test func bundleContextNilWithoutSignals() {
        #expect(bundleContextFromEnvironment(env: [:], bundleResolver: { _ in nil }) == nil)
    }

    @Test func ancestryGhosttySkippedWhenEmbedderDiffers() throws {
        // TERM_PROGRAM says ghostty, but __CFBundleIdentifier resolved the real embedder
        // (Cursor.app) — the ancestry's Ghostty.app entry must NOT override it.
        let (root, bundle) = try makeAppBundle("Cursor.app")
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = BundleContext(app: "Cursor.app", path: bundle.path,
                                bundleId: "com.todesktop", source: "__CFBundleIdentifier")
        let ancestry = [ProcessNode(pid: 10, ppid: 1, name: "ghostty", command: "/Applications/Ghostty.app/Contents/MacOS/ghostty")]
        let host = resolveHostContext(ancestry: ancestry, terminalApp: "Ghostty.app",
                                      bundleContext: ctx, findBundle: { _ in nil })
        #expect(host.hostApp == "Cursor.app")
        #expect(host.hostAppSource == "__CFBundleIdentifier")
        #expect(host.effectiveContext == "Cursor")
    }

    @Test func ancestryProcessStillWinsWhenMatchingBundle() {
        let ancestry = [ProcessNode(pid: 10, ppid: 1, name: "ghostty", command: "ghostty")]
        let host = resolveHostContext(ancestry: ancestry, terminalApp: "Ghostty.app",
                                      bundleContext: nil, findBundle: { _ in nil })
        #expect(host.hostApp == "Ghostty.app")
        #expect(host.hostAppSource == "process")
        #expect(host.effectiveContext == "Ghostty")
    }

    @Test func ancestryCommandPathHintResolves() throws {
        let (root, bundle) = try makeAppBundle("Zed Preview.app")
        defer { try? FileManager.default.removeItem(at: root) }
        let ancestry = [ProcessNode(pid: 10, ppid: 1, name: "unknown-helper",
                                    command: "\(bundle.path)/Contents/MacOS/zed --flag")]
        let host = resolveHostContext(ancestry: ancestry, terminalApp: nil,
                                      bundleContext: nil, findBundle: { _ in nil })
        #expect(host.hostApp == "Zed Preview.app")
        #expect(host.hostAppPath == bundle.path)
        #expect(host.hostAppSource == "process_command")
        #expect(host.effectiveContext == "Zed Preview")
    }

    @Test func contextJSONIncludesNewKeys() {
        let context = doctorExecutionContext(env: [:])
        for key in ["host_app_path", "host_bundle_id", "host_app_source"] {
            #expect(context.keys.contains(key), "missing \(key)")
        }
        let (result, _, _) = DoctorRuntime.buildResult(checks: [], context: context, forAgent: false)
        let json = result.serialized(indent: nil, ensureAscii: true)
        #expect(json.contains("\"host_app_path\""))
        #expect(json.contains("\"host_app_source\""))
    }
}
