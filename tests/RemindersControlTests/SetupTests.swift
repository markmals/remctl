import Testing
import Foundation
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// SetupTests — drive Setup.perform (the testable core) with injected env.
//
// All tests redirect HOME + REMCTL_CONFIG_DIR to temp dirs so CI never
// writes to the real home directory.
// ──────────────────────────────────────────────────────────────────────────────

private func makeTempEnv() throws -> (tmpDir: URL, env: [String: String]) {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("remctl-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let configDir = tmp.appendingPathComponent("config")
    let env: [String: String] = [
        "HOME": tmp.path,
        "REMCTL_CONFIG_DIR": configDir.path,
        "SHELL": "/bin/zsh",
    ]
    return (tmp, env)
}

@Suite struct SetupTests {

    // MARK: - setupCreatesConfigDir

    @Test("setup creates CONFIG_DIR (and best-effort chmod; mode assertion is no-throw)")
    func setupCreatesConfigDir() throws {
        let (tmp, env) = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configDir = URL(fileURLWithPath: env["REMCTL_CONFIG_DIR"]!)
        #expect(!FileManager.default.fileExists(atPath: configDir.path))

        let result = try Setup.perform(shellArg: "skip", doctor: false, json: true, env: env)
        #expect(result.exitCode == 0)

        #expect(FileManager.default.fileExists(atPath: configDir.path))

        // Best-effort chmod: assert it does not crash (mode may be unobservable on CI FS)
        // If we can read the attributes, assert 0700 mask is set.
        let attrs = try? FileManager.default.attributesOfItem(atPath: configDir.path)
        if let mode = attrs?[.posixPermissions] as? Int {
            // 0700 == 448 decimal; mask against 0777 to strip sticky/setuid bits
            #expect(mode & 0o777 == 0o700, "expected 0700, got \(String(mode, radix: 8))")
        }
    }

    // MARK: - setupInstallsCompletion

    @Test("setup --shell zsh installs completion file at ~/.zsh/completions/_remctl")
    func setupInstallsCompletion() throws {
        let (tmp, env) = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try Setup.perform(shellArg: "zsh", doctor: false, json: false, env: env)
        #expect(result.exitCode == 0)

        let completionPath = tmp.appendingPathComponent(".zsh/completions/_remctl")
        #expect(FileManager.default.fileExists(atPath: completionPath.path))

        let content = try String(contentsOf: completionPath, encoding: .utf8)
        #expect(content == CompletionScripts.zsh)
    }

    // MARK: - setupSkip

    @Test("setup --shell skip skips completion install; result completion fields are nil")
    func setupSkip() throws {
        let (tmp, env) = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try Setup.perform(shellArg: "skip", doctor: false, json: false, env: env)
        #expect(result.exitCode == 0)

        // No completion file anywhere under HOME
        let zshPath = tmp.appendingPathComponent(".zsh/completions/_remctl")
        #expect(!FileManager.default.fileExists(atPath: zshPath.path))

        // Human output should say "skipped"
        #expect(result.stdout.contains("Shell completion: skipped"))

        // JSON output should have null completion_shell and completion_path
        let jsonResult = try Setup.perform(shellArg: "skip", doctor: false, json: true, env: env)
        let data = Data(jsonResult.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["completion_shell"] is NSNull)
        #expect(obj?["completion_path"] is NSNull)
    }

    // MARK: - setupAutoDetect

    @Test("setup --shell auto with SHELL=/bin/zsh resolves to zsh")
    func setupAutoDetectZsh() throws {
        var (tmp, env) = try makeTempEnv()
        env["SHELL"] = "/bin/zsh"
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try Setup.perform(shellArg: "auto", doctor: false, json: true, env: env)
        #expect(result.exitCode == 0)

        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["completion_shell"] as? String == "zsh")
    }

    @Test("setup --shell auto with SHELL=/bin/tcsh resolves to skip")
    func setupAutoDetectTcsh() throws {
        var (tmp, env) = try makeTempEnv()
        env["SHELL"] = "/bin/tcsh"
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try Setup.perform(shellArg: "auto", doctor: false, json: true, env: env)
        #expect(result.exitCode == 0)

        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["completion_shell"] is NSNull)
        #expect(obj?["completion_path"] is NSNull)
    }

    // MARK: - setupJSON

    @Test("setup --json emits correct key order: ok, config_dir, completion_shell, completion_path")
    func setupJSON() throws {
        let (tmp, env) = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try Setup.perform(shellArg: "zsh", doctor: false, json: true, env: env)
        #expect(result.exitCode == 0)

        // Verify it's valid JSON and has expected keys with correct types
        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["ok"] as? Bool == true)
        #expect(obj?["config_dir"] is String)
        #expect(obj?["completion_shell"] as? String == "zsh")
        #expect(obj?["completion_path"] is String)

        // Verify key ORDER by checking the raw JSON string
        let text = result.stdout
        // indent=2 → first key on its own indented line
        #expect(text.contains("\n  \"ok\":"))
        // Check key order: ok before config_dir before completion_shell before completion_path
        let okIdx = text.range(of: "\"ok\":")?.lowerBound
        let cdIdx = text.range(of: "\"config_dir\":")?.lowerBound
        let csIdx = text.range(of: "\"completion_shell\":")?.lowerBound
        let cpIdx = text.range(of: "\"completion_path\":")?.lowerBound
        #expect(okIdx != nil && cdIdx != nil && csIdx != nil && cpIdx != nil)
        if let ok = okIdx, let cd = cdIdx, let cs = csIdx, let cp = cpIdx {
            #expect(ok < cd)
            #expect(cd < cs)
            #expect(cs < cp)
        }
    }

    // MARK: - setupHuman

    @Test("setup human output matches exact RemCTL setup block")
    func setupHuman() throws {
        let (tmp, env) = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configDir = env["REMCTL_CONFIG_DIR"]!
        let result = try Setup.perform(shellArg: "zsh", doctor: false, json: false, env: env)
        #expect(result.exitCode == 0)

        let out = result.stdout
        // First line: "RemCTL setup" (may be bold in some contexts, but NO_COLOR strips it)
        #expect(out.contains("RemCTL setup"))
        // Config directory line
        #expect(out.contains("Config directory: \(configDir)"))
        // Completion path (zsh target)
        let completionPath = tmp.path + "/.zsh/completions/_remctl"
        #expect(out.contains("Shell completion: \(completionPath)"))
        // Blank line before "Next:"
        #expect(out.contains("\nNext:"))
        // All three "Next:" lines
        #expect(out.contains("1. remctl onboard   # trigger macOS Reminders and Automation prompts"))
        #expect(out.contains("2. remctl permissions full-disk-access   # visual Full Disk Access setup"))
        #expect(out.contains("3. remctl doctor    # verify the CLI"))
    }

    // MARK: - setupDoctorJSON

    @Test("setup --doctor --json adds doctor sub-key with ONLY {ok, checks} (smaller shape; no warnings/failures/context)")
    func setupDoctorJSON() throws {
        let (tmp, env) = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try Setup.perform(shellArg: "skip", doctor: true, json: true, env: env)
        #expect(result.exitCode == 0, "--doctor --json must never exit non-zero")

        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Top-level setup keys
        #expect(obj?["ok"] as? Bool == true)
        #expect(obj?["config_dir"] is String)

        // doctor sub-key
        let doctorObj = obj?["doctor"] as? [String: Any]
        #expect(doctorObj != nil, "doctor key must be present with --doctor flag")
        #expect(doctorObj?["ok"] is Bool)
        #expect(doctorObj?["checks"] is [[String: Any]])

        // SMALLER shape: must NOT have warnings, failures, or context
        #expect(doctorObj?["warnings"] == nil, "doctor sub-key must NOT have 'warnings'")
        #expect(doctorObj?["failures"] == nil, "doctor sub-key must NOT have 'failures'")
        #expect(doctorObj?["context"] == nil, "doctor sub-key must NOT have 'context'")
    }
}

// MARK: - CLIRunner integration tests for setup

@Suite struct SetupCLITests {

    @Test("setup --shell zsh exits 0 and emits RemCTL setup header")
    func cliSetupBasic() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-setup-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configDir = tmp.appendingPathComponent("config")
        let result = try CLIRunner.run(
            ["setup", "--shell", "zsh"],
            extraEnv: ["HOME": tmp.path, "REMCTL_CONFIG_DIR": configDir.path])
        #expect(result.exit == 0)
        #expect(result.stdout.contains("RemCTL setup"))
        #expect(result.stdout.contains("Config directory:"))
        #expect(result.stdout.contains("Shell completion:"))
    }

    @Test("setup --shell skip exits 0 and says skipped")
    func cliSetupSkip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-setup-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configDir = tmp.appendingPathComponent("config")
        let result = try CLIRunner.run(
            ["setup", "--shell", "skip"],
            extraEnv: ["HOME": tmp.path, "REMCTL_CONFIG_DIR": configDir.path])
        #expect(result.exit == 0)
        #expect(result.stdout.contains("Shell completion: skipped"))
    }

    @Test("setup --json emits valid JSON with ok/config_dir/completion_shell/completion_path")
    func cliSetupJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-setup-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configDir = tmp.appendingPathComponent("config")
        let result = try CLIRunner.run(
            ["setup", "--shell", "zsh", "--json"],
            extraEnv: ["HOME": tmp.path, "REMCTL_CONFIG_DIR": configDir.path])
        #expect(result.exit == 0)
        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["ok"] as? Bool == true)
        #expect(obj?["config_dir"] is String)
        #expect(obj?["completion_shell"] as? String == "zsh")
        #expect(obj?["completion_path"] is String)
    }

    @Test("setup --doctor --json adds doctor sub-key and never exits non-zero")
    func cliSetupDoctorJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-setup-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configDir = tmp.appendingPathComponent("config")
        // Use a bogus REMCTL_STORE_DIR so doctor checks have fails, but --json must still exit 0
        let bogusStore = tmp.appendingPathComponent("no-store")
        let result = try CLIRunner.run(
            ["setup", "--shell", "skip", "--doctor", "--json"],
            storeDir: bogusStore,
            extraEnv: ["HOME": tmp.path, "REMCTL_CONFIG_DIR": configDir.path])
        #expect(result.exit == 0, "--doctor --json must never exit non-zero")

        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let doctorObj = obj?["doctor"] as? [String: Any]
        #expect(doctorObj != nil)
        #expect(doctorObj?["ok"] is Bool)
        #expect(doctorObj?["checks"] is [[String: Any]])
        // Smaller shape: no top-level doctor fields
        #expect(doctorObj?["warnings"] == nil)
        #expect(doctorObj?["failures"] == nil)
        #expect(doctorObj?["context"] == nil)
    }
}
