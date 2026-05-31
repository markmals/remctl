import Testing
import Foundation
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// OnboardTests — drive `Onboard.perform` with ALL side effects behind injected
// no-op recorders, a fixed `now`, and a temp `REMCTL_CONFIG_DIR`.
//
// NONE of the real side effects fire in CI:
//   • `open -a Reminders`            → `openApp` no-op recorder
//   • EventKit TCC prompt            → `eventKitAuthorize` injected outcome
//   • osascript Automation TCC prompt→ `automationProbe` injected outcome
//   • open System Settings (FDA)     → `openSettings` recorder
//   • pbcopy clipboard write         → `copyClipboard` recorder
//   • store-readability / db-path    → injected `storeAccessError` / `dbPath`
//
// The ONLY real side effect is the onboard-state.json write, which is pointed at
// a temp dir via REMCTL_CONFIG_DIR and stamped with the injected `now`.
// ──────────────────────────────────────────────────────────────────────────────

// MARK: - Helpers

/// Make a fresh temp dir, return an env that points REMCTL_CONFIG_DIR at it.
private func tempConfigEnv() -> (env: [String: String], dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("remctl-onboard-tests-\(UUID().uuidString)")
    var e: [String: String] = [
        "HOME": "/tmp/remctl-onboard-tests-home",
        "REMCTL_CONFIG_DIR": dir.path,
        "REMCTL_STORE_DIR": "/tmp/remctl-onboard-tests/store",
        "SHELL": "/bin/zsh",
        "TERM_PROGRAM": "",
    ]
    e["NO_COLOR"] = "1"  // belt-and-suspenders; tests also pass Ansi(enabled:false)
    return (e, dir)
}

/// A fixed clock: 2026-05-30T14:30:00 LOCAL (matches Python isoformat(timespec="seconds")).
private func fixedNow() -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 5; c.day = 30
    c.hour = 14; c.minute = 30; c.second = 0; c.nanosecond = 0
    return Calendar.current.date(from: c)!
}

/// The ISO seconds string the fixed clock must serialize to.
private let fixedNowISO = "2026-05-30T14:30:00"

/// Recorders for all injected effect seams.
private final class Recorders {
    var openAppCalls = 0
    var settingsURLs: [String] = []
    var clipboardWrites: [String] = []
}

/// Drive `Onboard.perform` with the given probe outcomes; all GUI/clipboard seams
/// are recorders. Returns the outcome + recorders + config dir.
private func runOnboard(
    json: Bool,
    eventKit: (ok: Bool, detail: String, fix: String?),
    automation: (ok: Bool, detail: String, fix: String?),
    storeAccessError: String?,
    dbPath: String?,
    settingsOpenRC: Int32 = 0
) async -> (outcome: WriteOutcome, rec: Recorders, dir: URL) {
    let (env, dir) = tempConfigEnv()
    let rec = Recorders()
    let outcome = await Onboard.perform(
        auto: false,
        json: json,
        storeAccessError: storeAccessError,
        dbPath: dbPath,
        now: fixedNow(),
        env: env,
        ansi: Ansi(enabled: false),
        openApp: { rec.openAppCalls += 1 },
        eventKitAuthorize: { eventKit },
        automationProbe: { automation },
        openSettings: { urls in rec.settingsURLs.append(contentsOf: urls); return settingsOpenRC },
        copyClipboard: { text in rec.clipboardWrites.append(text); return false }
    )
    return (outcome, rec, dir)
}

private func readStateFile(_ dir: URL) -> [String: Any]? {
    let url = dir.appendingPathComponent("onboard-state.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - All OK

@Suite struct OnboardAllOkTests {

    @Test("all probes ok → result ok:true, 0 failures, exit 0; state file written")
    func onboardAllOk() async throws {
        let (outcome, _, dir) = await runOnboard(
            json: true,
            eventKit: (true, "Reminders access granted to /path/to/remctl (3 lists, default: Reminders).", nil),
            automation: (true, "AppleScript automation access confirmed.", nil),
            storeAccessError: nil,
            dbPath: "/Users/me/Library/.../Data-1.sqlite"
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)

        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        #expect(json["ok"] as? Bool == true)
        #expect(json["failures"] as? Int == 0)
        #expect(json["warnings"] as? Int == 0)
        let checks = try #require(json["checks"] as? [[String: Any]])
        #expect(checks.count == 4)
        #expect(checks.map { $0["name"] as? String } == ["open_reminders", "eventkit", "automation", "database"])

        // State file written with injected ISO clock.
        let state = try #require(readStateFile(dir))
        #expect(state["seenAt"] as? String == fixedNowISO)
        #expect(state["ok"] as? Bool == true)
        #expect(state["failures"] as? Int == 0)
    }
}

// MARK: - Failures

@Suite struct OnboardFailureTests {

    @Test("eventkit fails → failures counted, exit 1, the check's detail/fix present")
    func onboardEventkitFails() async throws {
        let (outcome, _, _) = await runOnboard(
            json: true,
            eventKit: (false, "Reminders authorization failed.",
                       "Re-run `remctl onboard` from the same terminal and click Allow when macOS asks for Reminders access."),
            automation: (true, "AppleScript automation access confirmed.", nil),
            storeAccessError: nil,
            dbPath: "/Users/me/Data-1.sqlite"
        )

        #expect(outcome.exitCode == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        #expect(json["ok"] as? Bool == false)
        #expect(json["failures"] as? Int == 1)

        let checks = try #require(json["checks"] as? [[String: Any]])
        let ek = try #require(checks.first { $0["name"] as? String == "eventkit" })
        #expect(ek["status"] as? String == "fail")
        #expect(ek["detail"] as? String == "Reminders authorization failed.")
        #expect((ek["fix"] as? String)?.contains("click Allow when macOS asks") == true)
    }

    @Test("database fails (store access error) → exit 1; FDA fix uses 'remctl doctor --for-agent'")
    func onboardDbFails() async throws {
        let accessErr = "Direct CLI reads are blocked because the Reminders store at /store is not readable from this process context (/bin/remctl)."
        let (outcome, _, _) = await runOnboard(
            json: true,
            eventKit: (true, "Reminders access granted.", nil),
            automation: (true, "AppleScript automation access confirmed.", nil),
            storeAccessError: accessErr,
            dbPath: nil
        )

        #expect(outcome.exitCode == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        #expect(json["failures"] as? Int == 1)

        let checks = try #require(json["checks"] as? [[String: Any]])
        let db = try #require(checks.first { $0["name"] as? String == "database" })
        #expect(db["status"] as? String == "fail")
        #expect(db["detail"] as? String == accessErr)
        // The DB-check fix uses the --for-agent rerun command (distinct from the printed guidance).
        #expect((db["fix"] as? String)?.contains("remctl doctor --for-agent") == true)
    }

    @Test("database fails (no db found) → exit 1, 'No Reminders database found.' + onboard rerun fix")
    func onboardDbNotFound() async throws {
        let (outcome, _, _) = await runOnboard(
            json: true,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: nil,
            dbPath: nil
        )

        #expect(outcome.exitCode == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        let checks = try #require(json["checks"] as? [[String: Any]])
        let db = try #require(checks.first { $0["name"] as? String == "database" })
        #expect(db["status"] as? String == "fail")
        #expect(db["detail"] as? String == "No Reminders database found.")
        #expect((db["fix"] as? String)?.contains("Enable iCloud Reminders") == true)
        #expect((db["fix"] as? String)?.contains("remctl onboard") == true)
    }
}

// MARK: - JSON mode fires nothing beyond the checks

@Suite struct OnboardJSONModeTests {

    @Test("--json: result serialized indent=2; NO Settings/clipboard fired; state still written")
    func onboardJSONNoGuidance() async throws {
        // db check needs FDA, BUT json mode must NOT fire helper/Settings/clipboard.
        let accessErr = "Full Disk Access is missing; the Reminders store is not readable."
        let (outcome, rec, dir) = await runOnboard(
            json: true,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: accessErr,
            dbPath: nil
        )

        // No GUI/clipboard side effects.
        #expect(rec.settingsURLs.isEmpty, "JSON mode must NOT open Settings")
        #expect(rec.clipboardWrites.isEmpty, "JSON mode must NOT touch the clipboard")

        // Output is indent=2 serialized JSON ending in a newline.
        #expect(outcome.stdout.contains("  \"ok\""), "expected 2-space indented JSON")
        #expect(outcome.stdout.hasSuffix("\n"))
        #expect(!outcome.stdout.contains("RemCTL onboard"), "JSON mode prints no human header")
        #expect(!outcome.stdout.contains("Full Disk Access\n"), "JSON mode prints no guidance block")

        // exit 1 because db failed.
        #expect(outcome.exitCode == 1)

        // State file still written.
        let state = try #require(readStateFile(dir))
        #expect(state["seenAt"] as? String == fixedNowISO)
    }

    @Test("--json: openApp still fires (the 4 checks run in BOTH modes, per source)")
    func onboardJSONStillRunsChecks() async throws {
        let (_, rec, _) = await runOnboard(
            json: true,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: nil,
            dbPath: "/db.sqlite"
        )
        // openApp is one of the 4 check seams; it runs even in JSON mode (matches Python:
        // run_onboarding runs gather_onboarding_checks before the json branch).
        #expect(rec.openAppCalls == 1, "openApp seam runs in JSON mode (real side effect injected as no-op)")
    }
}

// MARK: - Human-mode FDA guidance

@Suite struct OnboardHumanGuidanceTests {

    @Test("human + db needs FDA → openSettings fired + guidance text; two distinct rerun strings present")
    func onboardHumanGuidanceWhenDbNeedsFDA() async throws {
        let accessErr = "Full Disk Access is missing; the Reminders store is not readable from this process."
        let (outcome, rec, _) = await runOnboard(
            json: false,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: accessErr,
            dbPath: nil,
            settingsOpenRC: 0
        )

        // openSettings WAS fired in human mode (the helper degrades → guidance opens Settings).
        #expect(!rec.settingsURLs.isEmpty, "expected openSettings to be called in human mode FDA branch")
        #expect(rec.settingsURLs.first == fullDiskAccessSettingsURLs[0])

        // Human header + dim line + check report present.
        #expect(outcome.stdout.contains("RemCTL onboard"))
        #expect(outcome.stdout.contains("Approve any macOS prompts for Reminders or Automation access."))

        // Guidance block present.
        #expect(outcome.stdout.contains("Full Disk Access"))

        // The TWO distinct rerun strings both appear (db-check fix vs printed guidance).
        #expect(outcome.stdout.contains("remctl doctor --for-agent"), "db-check fix rerun string")
        // The guidance's own rerun is the bare 'remctl doctor' — appears in the guidance tail.
        #expect(outcome.stdout.contains("rerun `remctl doctor`"), "guidance rerun string")

        // exit 1 because db failed.
        #expect(outcome.exitCode == 1)
    }

    @Test("human + all ok (db has no FDA) → openSettings NOT fired; exit 0")
    func onboardHumanNoGuidanceWhenOk() async throws {
        let (outcome, rec, _) = await runOnboard(
            json: false,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: nil,
            dbPath: "/db.sqlite"
        )
        #expect(rec.settingsURLs.isEmpty, "no FDA guidance when db check is ok")
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("RemCTL onboard"))
    }
}

// MARK: - State file shape

@Suite struct OnboardStateFileShapeTests {

    @Test("onboard-state.json has exact keys + injected ISO + trailing newline")
    func onboardStateFileShape() async throws {
        let (_, _, dir) = await runOnboard(
            json: true,
            eventKit: (true, "ok", nil),
            automation: (false, "automation warn", "approve the Automation prompt"),
            storeAccessError: nil,
            dbPath: "/db.sqlite"
        )

        // Raw bytes: trailing newline + indent=2.
        let url = dir.appendingPathComponent("onboard-state.json")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(raw.hasSuffix("\n"), "state file must end with a trailing newline")
        #expect(raw.contains("  \"version\""), "expected 2-space indented JSON")

        let state = try #require(readStateFile(dir))
        // Exact key set.
        #expect(Set(state.keys) == Set(["version", "seenAt", "auto", "ok", "warnings", "failures"]))
        #expect(state["version"] as? String == remctlVersion)
        #expect(state["seenAt"] as? String == fixedNowISO)
        #expect(state["auto"] as? Bool == false)
        #expect(state["ok"] as? Bool == true)   // automation is WARN not FAIL → ok true
        #expect(state["warnings"] as? Int == 1)
        #expect(state["failures"] as? Int == 0)
    }
}

// MARK: - needsFullDiskAccessGuidance wiring through onboard's db check

@Suite struct OnboardFDAGuidanceWiringTests {

    @Test("the db check produced by onboard with an FDA access error trips needsFullDiskAccessGuidance")
    func wiringTrue() async throws {
        let accessErr = "Full Disk Access is missing; store unreadable."
        let (outcome, _, _) = await runOnboard(
            json: true,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: accessErr,
            dbPath: nil
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        let checks = try #require(json["checks"] as? [[String: Any]])
        let dbDict = try #require(checks.first { $0["name"] as? String == "database" })
        let check = DoctorCheck(
            name: "database",
            status: .fail,
            detail: dbDict["detail"] as? String ?? "",
            fix: dbDict["fix"] as? String
        )
        #expect(needsFullDiskAccessGuidance(check), "FDA access-error db check must trip guidance")
    }

    @Test("an ok db check does NOT trip needsFullDiskAccessGuidance")
    func wiringFalse() async throws {
        let (outcome, _, _) = await runOnboard(
            json: true,
            eventKit: (true, "ok", nil),
            automation: (true, "ok", nil),
            storeAccessError: nil,
            dbPath: "/db.sqlite"
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        let checks = try #require(json["checks"] as? [[String: Any]])
        let dbDict = try #require(checks.first { $0["name"] as? String == "database" })
        let check = DoctorCheck(
            name: "database",
            status: .ok,
            detail: dbDict["detail"] as? String ?? "",
            fix: dbDict["fix"] as? String
        )
        #expect(!needsFullDiskAccessGuidance(check))
    }
}
