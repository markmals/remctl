import Testing
import Foundation
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// PermissionsTests — drive `Permissions.perform` and the FDA helper family.
//
// All injected seams (`openSettings`, `runPbcopy`) are recorders: no real GUI
// opens, no real clipboard writes, no System Settings launched in CI.
//
// `REMCTL_STORE_DIR` + `REMCTL_PERMISSIONS_PATH` are fixed via injected `env`
// for deterministic path values in JSON assertions.
// ──────────────────────────────────────────────────────────────────────────────

// MARK: - Helpers

/// Build a minimal deterministic env for tests.
/// Sets HOME to a stable temp path and fixes the binary path for the helper key.
private func stubEnv(remctlPermissionsPath: String? = nil) -> [String: String] {
    var e: [String: String] = [
        "HOME": "/tmp/remctl-tests",
        "REMCTL_STORE_DIR": "/tmp/remctl-tests/store",
        // No REMCTL_CONFIG_DIR — falls through to ~/.config/remctl under stubbed HOME.
        "SHELL": "/bin/zsh",
        // Clear TERM_PROGRAM so terminal-app detection is consistent.
        "TERM_PROGRAM": "",
    ]
    if let p = remctlPermissionsPath { e["REMCTL_PERMISSIONS_PATH"] = p }
    return e
}

// MARK: - Topic validation

@Suite struct PermissionsTopicValidationTests {

    @Test("wrong topic → stderr 'Error: Unsupported permissions topic ...' exit 1")
    func topicValidation() throws {
        let outcome = try Permissions.perform(
            topic: "wrong-topic",
            wait: false,
            json: false,
            env: stubEnv()
        )
        #expect(outcome.exitCode == 1)
        #expect(outcome.stderr == "Error: Unsupported permissions topic 'wrong-topic'\n")
        #expect(outcome.stdout.isEmpty)
    }

    @Test("empty topic → exit 1 with correct message")
    func emptyTopicValidation() throws {
        let outcome = try Permissions.perform(
            topic: "",
            wait: false,
            json: false,
            env: stubEnv()
        )
        #expect(outcome.exitCode == 1)
        #expect(outcome.stderr.hasPrefix("Error: Unsupported permissions topic ''"))
    }

    @Test("only 'full-disk-access' is accepted as a valid topic")
    func validTopicAccepted() throws {
        // Should NOT produce exit 1 for the valid topic (human mode, noop seams).
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: false,
            env: stubEnv(),
            openSettings: { _ in 0 },
            runPbcopy: { _ in false }
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
    }
}

// MARK: - JSON shape

@Suite struct PermissionsJSONTests {

    /// The JSON output must include `helper`, `available`, `targets`.
    /// `available` must be `false` (no bundled helper).
    /// No open/clipboard side effects fire in JSON mode.
    @Test("--json: shape {helper, available:false, targets:[...]}")
    func jsonShape() throws {
        var openCalled = false
        var pbcopyCalled = false

        let env = stubEnv(remctlPermissionsPath: "/tmp/remctl-permissions")
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: true,
            env: env,
            openSettings: { _ in openCalled = true; return 0 },
            runPbcopy: { _ in pbcopyCalled = true; return false }
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)

        // No GUI or clipboard side effects fired.
        #expect(!openCalled, "open should NOT be called in JSON mode")
        #expect(!pbcopyCalled, "pbcopy should NOT be called in JSON mode")

        // Parse the JSON output.
        let data = Data(outcome.stdout.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Output is not valid JSON: \(outcome.stdout)")
            return
        }

        // Required keys.
        #expect(json["helper"] != nil, "missing 'helper' key")
        #expect(json["available"] != nil, "missing 'available' key")
        #expect(json["targets"] != nil, "missing 'targets' key")

        // available must be false (hardcoded — no bundled helper).
        #expect(json["available"] as? Bool == false,
                "expected available:false, got \(String(describing: json["available"]))")

        // helper must be a non-empty string (the would-be helper path).
        let helperVal = json["helper"] as? String
        #expect(helperVal != nil, "helper must be a String")
        #expect(!(helperVal ?? "").isEmpty, "helper must not be empty")

        // targets must be an array.
        #expect(json["targets"] is [Any], "targets must be an array")

        // Verify 2-space indent in raw output.
        #expect(outcome.stdout.contains("  \"helper\""), "expected 2-space indented JSON")
    }

    @Test("--json: helper key is the currentPermissionsPath, not the remctl binary")
    func jsonHelperKey() throws {
        let expectedHelperPath = "/tmp/test-remctl-permissions"
        let env = stubEnv(remctlPermissionsPath: expectedHelperPath)
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: true,
            env: env,
            openSettings: { _ in 0 },
            runPbcopy: { _ in false }
        )
        #expect(outcome.exitCode == 0)
        let data = Data(outcome.stdout.utf8)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(json["helper"] as? String == expectedHelperPath)
        }
    }

    @Test("--json: targets array entries have title/path/subtitle keys")
    func jsonTargetsShape() throws {
        let env = stubEnv()
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: true,
            env: env,
            openSettings: { _ in 0 },
            runPbcopy: { _ in false }
        )
        #expect(outcome.exitCode == 0)
        let data = Data(outcome.stdout.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = json["targets"] as? [[String: Any]] else { return }
        for target in targets {
            #expect(target["title"] is String, "target missing 'title'")
            #expect(target["path"] is String, "target missing 'path'")
            #expect(target["subtitle"] is String, "target missing 'subtitle'")
        }
    }

    @Test("--json: targets are deduplicated by lowercased path")
    func jsonTargetsDeduped() throws {
        // fullDiskAccessTargetSpecs deduplicates by lowercased resolved path.
        // Verify no duplicate paths in the output.
        let env = stubEnv()
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: true,
            env: env,
            openSettings: { _ in 0 },
            runPbcopy: { _ in false }
        )
        let data = Data(outcome.stdout.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = json["targets"] as? [[String: Any]] else { return }
        let paths = targets.compactMap { $0["path"] as? String }.map { $0.lowercased() }
        let uniquePaths = Set(paths)
        #expect(paths.count == uniquePaths.count, "duplicate paths: \(paths)")
    }
}

// MARK: - Human mode (opens Settings, prints guidance)

@Suite struct PermissionsHumanModeTests {

    @Test("human mode: injected open receives settings URLs; guidance printed; exit 0")
    func humanOpensSettings() throws {
        var openedURLs: [String] = []
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: false,
            env: stubEnv(),
            openSettings: { args in
                openedURLs.append(contentsOf: args)
                return 0   // success on first URL → stops iterating
            },
            runPbcopy: { _ in false }
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)

        // At least one Settings URL was opened.
        #expect(!openedURLs.isEmpty, "expected openSettings to be called with a URL")
        let knownURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        #expect(openedURLs.first == knownURL,
                "expected the first FDA settings URL, got \(openedURLs.first ?? "(none)")")

        // Output should contain guidance block.
        #expect(outcome.stdout.contains("Full Disk Access"), "expected guidance block in stdout")
    }

    @Test("human mode: no pbcopy call leaks when pbcopy is a recorder")
    func humanPbcopyRecorded() throws {
        var pbcopyInput: String? = nil
        let outcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: false,
            env: stubEnv(),
            openSettings: { _ in 0 },
            runPbcopy: { text in pbcopyInput = text; return true }
        )
        #expect(outcome.exitCode == 0)
        // pbcopy was called (we control whether it "succeeds"), and it received the runtime path.
        #expect(pbcopyInput != nil, "expected pbcopy to be called in human mode")
    }

    @Test("human mode: settings_opened=true → 'Opened System Settings' line; false → 'Open System Settings'")
    func humanSettingsOpenedText() throws {
        // When openSettings returns 0 (success) → "Opened"
        let openedOutcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: false,
            env: stubEnv(),
            openSettings: { _ in 0 },
            runPbcopy: { _ in false }
        )
        #expect(openedOutcome.stdout.contains("Opened System Settings"),
                "expected 'Opened System Settings' when settingsOpened=true")

        // When openSettings returns non-zero (failure) for ALL URLs → "Open" (imperative)
        let failedOutcome = try Permissions.perform(
            topic: "full-disk-access",
            wait: false,
            json: false,
            env: stubEnv(),
            openSettings: { _ in 1 },
            runPbcopy: { _ in false }
        )
        #expect(failedOutcome.stdout.contains("Open System Settings > Privacy"),
                "expected 'Open System Settings' when settingsOpened=false")
    }
}

// MARK: - fullDiskAccessFixText unit tests

@Suite struct FullDiskAccessFixTextTests {

    @Test("fullDiskAccessFixText (mention_onboard=false) contains expected lines")
    func fixTextNoOnboard() {
        let text = fullDiskAccessFixText(
            rerunCommand: "remctl doctor",
            mentionOnboard: false
        )
        #expect(text.contains("Full Disk Access is missing for this process context"))
        #expect(text.contains("Open System Settings > Privacy & Security > Full Disk Access"))
        #expect(text.contains("remctl permissions full-disk-access"))
        #expect(text.contains("remctl doctor"))
    }

    @Test("fullDiskAccessFixText (mention_onboard=true) contains onboard-specific intro")
    func fixTextWithOnboard() {
        let text = fullDiskAccessFixText(
            rerunCommand: "remctl doctor --for-agent",
            mentionOnboard: true
        )
        #expect(text.contains("`remctl onboard` can open a guided permission helper"))
        #expect(text.contains("remctl doctor --for-agent"))
    }

    @Test("fullDiskAccessFixText rerunCommand is correctly threaded through")
    func fixTextRerunCommand() {
        let customCmd = "remctl doctor --for-agent"
        let text = fullDiskAccessFixText(rerunCommand: customCmd, mentionOnboard: false)
        #expect(text.contains(customCmd), "custom rerun command not found in fix text")
    }
}

// MARK: - needsFullDiskAccessGuidance unit tests

@Suite struct NeedsFullDiskAccessGuidanceTests {

    @Test("nil check → false")
    func nilCheck() {
        #expect(!needsFullDiskAccessGuidance(nil))
    }

    @Test("check with 'Full Disk Access' in fix → true")
    func fixContainsFullDiskAccess() {
        let check = DoctorCheck(
            name: "database",
            status: .fail,
            detail: "store unreadable",
            fix: "Open System Settings > Full Disk Access and add the terminal."
        )
        #expect(needsFullDiskAccessGuidance(check))
    }

    @Test("check with 'Full Disk Access' in detail → true")
    func detailContainsFullDiskAccess() {
        let check = DoctorCheck(
            name: "database",
            status: .fail,
            detail: "Full Disk Access is missing for this process context",
            fix: "Run remctl permissions full-disk-access."
        )
        #expect(needsFullDiskAccessGuidance(check))
    }

    @Test("check without 'Full Disk Access' → false")
    func noFullDiskAccess() {
        let check = DoctorCheck(
            name: "cli",
            status: .ok,
            detail: "/usr/local/bin/remctl",
            fix: nil
        )
        #expect(!needsFullDiskAccessGuidance(check))
    }

    @Test("nil fix and no match in detail → false")
    func nilFixNoMatch() {
        let check = DoctorCheck(
            name: "database",
            status: .fail,
            detail: "No Reminders database found",
            fix: nil
        )
        #expect(!needsFullDiskAccessGuidance(check))
    }
}

// MARK: - fullDiskAccessTargets vs fullDiskAccessTargetSpecs (distinct shapes)

@Suite struct FullDiskAccessTargetShapesTests {

    @Test("fullDiskAccessTargets returns [String]; fullDiskAccessTargetSpecs returns [[(String,JSONValue)]]")
    func distinctShapes() {
        let env = stubEnv()
        let stringList = fullDiskAccessTargets(env: env)
        let specsList = fullDiskAccessTargetSpecs(includeCli: true, env: env)

        // String list: each entry is a formatted "title: path" string or a terminal hint.
        // (Type is statically [String], so we just verify non-empty structure.)
        for s in stringList {
            #expect(!s.isEmpty, "target string must be non-empty")
        }

        // Specs list: each entry is a [(String, JSONValue)] pair list with title/path/subtitle keys.
        for spec in specsList {
            let keys = spec.map { $0.0 }
            #expect(keys.contains("title"), "spec missing 'title'")
            #expect(keys.contains("path"), "spec missing 'path'")
            #expect(keys.contains("subtitle"), "spec missing 'subtitle'")
        }
    }

    @Test("fullDiskAccessTargets may append terminal-app hint when no .app target present")
    func targetsTerminalHint() {
        // With no TERM_PROGRAM and no bundled apps, the string list should have
        // at least one entry (the remctl runtime line) and possibly a terminal hint.
        let env = stubEnv()
        let targets = fullDiskAccessTargets(env: env)
        #expect(!targets.isEmpty, "targets should never be empty (runtime path always added)")
        // The first entry should be the "Current remctl runtime" line.
        #expect(targets[0].hasPrefix("Current remctl runtime:"), "expected runtime path as first target")
    }

    @Test("fullDiskAccessTargetSpecs(includeCli:false) returns empty list")
    func specsExcludeCli() {
        let specs = fullDiskAccessTargetSpecs(includeCli: false, env: stubEnv())
        #expect(specs.isEmpty, "includeCli:false should produce an empty list with no terminal apps found")
    }

    @Test("fullDiskAccessTargetSpecs deduplicates by lowercased resolved path")
    func specsDedup() {
        let env = stubEnv()
        let specs = fullDiskAccessTargetSpecs(includeCli: true, env: env)
        // Extract resolved paths (the 'path' JSONValue string from each spec).
        let paths: [String] = specs.compactMap { spec in
            if let pair = spec.first(where: { $0.0 == "path" }),
               case let .string(p) = pair.1 {
                return p.lowercased()
            }
            return nil
        }
        let unique = Set(paths)
        #expect(paths.count == unique.count, "duplicate paths in specs: \(paths)")
    }
}

// MARK: - permissionHelperAvailable + launchFullDiskAccessHelper

@Suite struct PermissionHelperHardcodedTests {

    @Test("permissionHelperAvailable() is always false (no bundled helper)")
    func helperAlwaysFalse() {
        #expect(!permissionHelperAvailable())
    }

    @Test("launchFullDiskAccessHelper always returns false")
    func launchAlwaysFalse() {
        #expect(!launchFullDiskAccessHelper(includeCli: true, wait: false))
        #expect(!launchFullDiskAccessHelper(includeCli: false, wait: false))
        #expect(!launchFullDiskAccessHelper(includeCli: true, wait: true))
    }
}

// MARK: - openFullDiskAccessSettings (injected open)

@Suite struct OpenFullDiskAccessSettingsTests {

    @Test("returns true when first URL open returns 0")
    func returnsTrue() {
        var calls: [[String]] = []
        let result = openFullDiskAccessSettings { args in
            calls.append(args)
            return 0
        }
        #expect(result)
        // Stops after first success — only one call.
        #expect(calls.count == 1)
        #expect(calls[0][0] == fullDiskAccessSettingsURLs[0])
    }

    @Test("returns false when all URL opens fail")
    func returnsFalse() {
        var calls: [[String]] = []
        let result = openFullDiskAccessSettings { args in
            calls.append(args)
            return 1
        }
        #expect(!result)
        // Should have tried all URLs.
        #expect(calls.count == fullDiskAccessSettingsURLs.count)
    }

    @Test("tries second URL when first fails")
    func triesSecondURL() {
        var callCount = 0
        let result = openFullDiskAccessSettings { _ in
            callCount += 1
            return callCount < 2 ? 1 : 0   // fail first, succeed second
        }
        #expect(result)
        #expect(callCount == 2)
    }
}

// MARK: - printPermissionHelperOpened

@Suite struct PrintPermissionHelperOpenedTests {

    @Test("returns multiline string with Guided Full Disk Access header")
    func output() {
        let text = printPermissionHelperOpened(ansi: Ansi(enabled: false))
        #expect(text.contains("Guided Full Disk Access"))
        #expect(text.contains("Opened the RemCTL permission helper."))
        #expect(text.contains("Command-Shift-G"))
        // Must start with blank line.
        #expect(text.hasPrefix("\n"), "expected leading blank line")
    }
}
