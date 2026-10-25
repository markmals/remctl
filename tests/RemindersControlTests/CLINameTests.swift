import Testing
import Foundation
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// CLINameTests — the CLI answers to remctl / rctl / reminders (upstream 5cb595a).
//
// Covers: argv[0] resolution (known names + fallback), the root command name,
// per-name completion scripts and install paths, setup's alias handling (temp dirs
// only — never the real HOME), doctor's name-aware hints, and the real binary
// invoked through symlinks named after each alias.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct CLINameResolutionTests {

    @Test("each known name survives argv[0] resolution",
          arguments: [("/opt/homebrew/bin/remctl", "remctl"),
                      ("/opt/homebrew/bin/rctl", "rctl"),
                      ("/opt/homebrew/bin/reminders", "reminders"),
                      ("remctl", "remctl"),
                      ("rctl", "rctl"),
                      ("reminders", "reminders"),
                      ("./rctl", "rctl")])
    func knownNames(argv0: String, expected: String) {
        #expect(CLIName.resolve(argv0: argv0) == expected)
    }

    @Test("an unknown argv[0] falls back to remctl",
          arguments: ["/opt/homebrew/bin/remctl2", "remindersctl", "Reminders", "REMCTL",
                      "/usr/bin/xctest", "", "/opt/bin/"])
    func unknownNames(argv0: String) {
        #expect(CLIName.resolve(argv0: argv0) == "remctl")
    }

    @Test("a missing argv[0] falls back to remctl")
    func missingArgv0() {
        #expect(CLIName.resolve(argv0: nil) == "remctl")
    }

    @Test("the resolved name is always one of the three known names")
    func currentIsKnown() {
        #expect(CLIName.all == ["remctl", "rctl", "reminders"])
        #expect(CLIName.all.contains(CLIName.current))
    }

    @Test("the root command is named after the invoked binary")
    func rootCommandName() {
        #expect(RemindersControl.configuration.commandName == CLIName.current)
        // The test runner is not a known name, so it resolves to the canonical one.
        #expect(RemindersControl.configuration.commandName == "remctl")
    }
}

@Suite struct AliasCompletionScriptTests {

    @Test("remctl scripts are returned unchanged")
    func canonicalScriptsAreVerbatim() {
        #expect(CompletionScripts.script(.zsh, commandName: "remctl") == CompletionScripts.zsh)
        #expect(CompletionScripts.script(.bash, commandName: "remctl") == CompletionScripts.bash)
        #expect(CompletionScripts.script(.fish, commandName: "remctl") == CompletionScripts.fish)
    }

    @Test("zsh script names the alias in compdef, function, and registration",
          arguments: ["rctl", "reminders"])
    func zshAlias(name: String) {
        let script = CompletionScripts.script(.zsh, commandName: name)
        #expect(script.hasPrefix("#compdef \(name)\n"))
        #expect(script.contains("_\(name)() {"))
        #expect(script.hasSuffix("compdef _\(name) \(name)\n"))
        #expect(!script.contains("remctl"))
        // Only tokens change: the script keeps its shape.
        #expect(script.components(separatedBy: "\n").count
            == CompletionScripts.zsh.components(separatedBy: "\n").count)
    }

    @Test("bash script names the alias in the function and complete registration",
          arguments: ["rctl", "reminders"])
    func bashAlias(name: String) {
        let script = CompletionScripts.script(.bash, commandName: name)
        #expect(script.hasPrefix("_\(name)() {\n"))
        #expect(script.hasSuffix("complete -F _\(name) \(name)\n"))
        #expect(!script.contains("remctl"))
        #expect(script.components(separatedBy: "\n").count
            == CompletionScripts.bash.components(separatedBy: "\n").count)
    }

    @Test("fish script completes the alias on every line", arguments: ["rctl", "reminders"])
    func fishAlias(name: String) {
        let script = CompletionScripts.script(.fish, commandName: name)
        #expect(script.hasPrefix("# Fish completion for \(name)\n"))
        #expect(script.contains("complete -c \(name) -n \"__fish_use_subcommand\" -a lists"))
        #expect(!script.contains("remctl"))
        #expect(script.components(separatedBy: "\n").count
            == CompletionScripts.fish.components(separatedBy: "\n").count)
    }

    @Test("completionScript(for:commandName:) dispatches per shell")
    func scriptLookup() throws {
        #expect(try completionScript(for: "zsh", commandName: "rctl")
            == CompletionScripts.script(.zsh, commandName: "rctl"))
        #expect(try completionScript(for: "bash", commandName: "reminders")
            == CompletionScripts.script(.bash, commandName: "reminders"))
        #expect(try completionScript(for: "fish", commandName: "reminders")
            == CompletionScripts.script(.fish, commandName: "reminders"))
        #expect(throws: CLIError.self) { try completionScript(for: "tcsh", commandName: "rctl") }
    }

    @Test("completion install paths are per name and per shell")
    func targetPaths() throws {
        let env = ["HOME": "/home/test"]
        #expect(try completionTargetPath("zsh", commandName: "rctl", env: env).path
            == "/home/test/.zsh/completions/_rctl")
        #expect(try completionTargetPath("bash", commandName: "reminders", env: env).path
            == "/home/test/.local/share/bash-completion/completions/reminders")
        #expect(try completionTargetPath("fish", commandName: "reminders", env: env).path
            == "/home/test/.config/fish/completions/reminders.fish")
        #expect(try completionTargetPath("zsh", commandName: "remctl", env: env).path
            == "/home/test/.zsh/completions/_remctl")
        #expect(throws: CLIError.self) { try completionTargetPath("tcsh", commandName: "rctl", env: env) }
    }
}

// MARK: - Alias discovery + setup

/// A temp bin directory holding executable stubs for `names`.
private func makeBinDir(_ names: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("remctl-alias-bin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in names {
        let path = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    return dir
}

private func makeHome() throws -> (home: URL, env: [String: String]) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("remctl-alias-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return (home, ["HOME": home.path,
                   "REMCTL_CONFIG_DIR": home.appendingPathComponent("config").path,
                   "SHELL": "/bin/zsh"])
}

@Suite struct AliasSetupTests {

    @Test("only the invoked name is used when no alias sits next to the binary")
    func noAliasesInstalled() throws {
        let bin = try makeBinDir(["remctl"])
        defer { try? FileManager.default.removeItem(at: bin) }
        #expect(completionCommandNames(invokedAs: "remctl", binaryDirectory: bin) == ["remctl"])
    }

    @Test("aliases next to the binary are picked up in install order")
    func aliasesBesideBinary() throws {
        let bin = try makeBinDir(["remctl", "rctl", "reminders"])
        defer { try? FileManager.default.removeItem(at: bin) }
        #expect(completionCommandNames(invokedAs: "remctl", binaryDirectory: bin)
            == ["remctl", "rctl", "reminders"])
        #expect(completionCommandNames(invokedAs: "rctl", binaryDirectory: bin)
            == ["remctl", "rctl", "reminders"])
    }

    @Test("the invoked name is always included, even when it is not in the directory")
    func invokedNameAlwaysIncluded() throws {
        let bin = try makeBinDir(["remctl"])
        defer { try? FileManager.default.removeItem(at: bin) }
        #expect(completionCommandNames(invokedAs: "reminders", binaryDirectory: bin)
            == ["remctl", "reminders"])
        #expect(completionCommandNames(invokedAs: "rctl", binaryDirectory: nil) == ["rctl"])
    }

    @Test("a non-executable file with an alias name is not treated as an install")
    func nonExecutableIgnored() throws {
        let bin = try makeBinDir(["remctl"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let stray = bin.appendingPathComponent("rctl")
        try Data("not a program".utf8).write(to: stray)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stray.path)
        #expect(completionCommandNames(invokedAs: "remctl", binaryDirectory: bin) == ["remctl"])
    }

    @Test("setup writes a completion file for the invoked name and every installed alias")
    func setupInstallsAliasCompletions() throws {
        let bin = try makeBinDir(["remctl", "rctl", "reminders"])
        let (home, env) = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: bin)
            try? FileManager.default.removeItem(at: home)
        }

        let result = try Setup.perform(
            shellArg: "zsh", doctor: false, json: true, env: env,
            cliName: "rctl", binaryDirectory: bin)
        #expect(result.exitCode == 0)

        let completions = home.appendingPathComponent(".zsh/completions")
        for name in ["remctl", "rctl", "reminders"] {
            let path = completions.appendingPathComponent("_\(name)")
            #expect(FileManager.default.fileExists(atPath: path.path), "missing _\(name)")
            let content = try String(contentsOf: path, encoding: .utf8)
            #expect(content == CompletionScripts.script(.zsh, commandName: name))
        }

        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect(obj?["completion_path"] as? String == completions.appendingPathComponent("_rctl").path)
        let aliasPaths = obj?["completion_alias_paths"] as? [String]
        #expect(aliasPaths == [completions.appendingPathComponent("_remctl").path,
                               completions.appendingPathComponent("_reminders").path])
    }

    @Test("setup reports alias files and the invoked name in human output")
    func setupHumanOutputNamesAliases() throws {
        let bin = try makeBinDir(["remctl", "reminders"])
        let (home, env) = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: bin)
            try? FileManager.default.removeItem(at: home)
        }

        let result = try Setup.perform(
            shellArg: "fish", doctor: false, json: false, env: env,
            cliName: "reminders", binaryDirectory: bin)
        let completions = home.appendingPathComponent(".config/fish/completions")
        #expect(result.stdout.contains(
            "Shell completion: \(completions.appendingPathComponent("reminders.fish").path)"))
        #expect(result.stdout.contains(
            "Alias completion: \(completions.appendingPathComponent("remctl.fish").path)"))
        #expect(result.stdout.contains("1. reminders onboard"))
        #expect(result.stdout.contains("2. reminders permissions full-disk-access"))
        #expect(result.stdout.contains("3. reminders doctor"))
    }

    @Test("setup --shell skip writes nothing, for aliases either")
    func setupSkipWritesNothing() throws {
        let bin = try makeBinDir(["remctl", "rctl", "reminders"])
        let (home, env) = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: bin)
            try? FileManager.default.removeItem(at: home)
        }

        let result = try Setup.perform(
            shellArg: "skip", doctor: false, json: true, env: env,
            cliName: "rctl", binaryDirectory: bin)
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".zsh/completions").path))
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect(obj?["completion_path"] is NSNull)
        #expect((obj?["completion_alias_paths"] as? [String])?.isEmpty == true)
    }
}

// MARK: - Doctor

@Suite struct AliasDoctorTests {

    private func probes(cliName: String, completionTarget: String?, completionExists: Bool,
                        shell: String = "zsh") -> DoctorProbes {
        DoctorProbes(
            isDarwin: true,
            platformDetail: "macOS 15.5",
            macOSDetail: "macOS 15.5",
            storeDirPath: "/tmp/store",
            storeDirExists: true,
            storeAccessError: nil,
            dbPath: "/tmp/store/Data-1.sqlite",
            cliPath: "/opt/homebrew/bin/remctl",
            cliExists: true,
            cliOnPath: true,
            cliName: cliName,
            eventKitAuthStatus: .fullAccess,
            reminderKitProbeResult: "reminderkit-ok",
            configDirPath: "/home/test/.config/remctl",
            configDirExists: false,
            shellName: shell,
            completionTargetPath: completionTarget,
            completionTargetExists: completionExists,
            fullDiskAccessFixText: { "FDA" })
    }

    @Test("the completion check reads the alias completion file and names the alias")
    func completionCheckForAlias() {
        let checks = gatherDoctorChecks(probes: probes(
            cliName: "rctl",
            completionTarget: "/home/test/.zsh/completions/_rctl",
            completionExists: false))
        let completion = checks.first { $0.name == "completion" }
        #expect(completion?.detail == "zsh: /home/test/.zsh/completions/_rctl")
        #expect(completion?.fix == "Run rctl setup --shell zsh to install completion.")
        #expect(checks.first { $0.name == "config_dir" }?.fix
            == "Run rctl setup to create config files.")
    }

    @Test("an unsupported shell names the alias in its fix hint")
    func unsupportedShellFix() {
        let checks = gatherDoctorChecks(probes: probes(
            cliName: "reminders", completionTarget: nil, completionExists: false, shell: "tcsh"))
        #expect(checks.first { $0.name == "completion" }?.fix
            == "Run reminders setup --shell zsh|bash|fish.")
    }

    @Test("the PATH scan looks for the given name")
    func whichUsesName() throws {
        let bin = try makeBinDir(["rctl"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let env = ["PATH": bin.path]
        #expect(whichCLI("rctl", env: env) == bin.appendingPathComponent("rctl").path)
        #expect(whichCLI("remctl", env: env) == nil)
        #expect(whichCLI("rctl", env: [:]) == nil)
    }
}

// MARK: - The real binary, invoked through each name

/// Runs the built binary through a symlink named `name`, so argv[0] carries it.
private func runAs(_ name: String, _ args: [String]) throws -> (stdout: String, stderr: String, exit: Int32) {
    try CLIRunner.ensureBuilt()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("remctl-alias-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appendingPathComponent(name)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: CLIRunner.binaryURL())

    let process = Process()
    process.executableURL = link
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    return (stdout, stderr, process.terminationStatus)
}

@Suite struct AliasBinaryTests {

    @Test("help and usage name the invoked binary", arguments: ["remctl", "rctl", "reminders"])
    func helpNamesBinary(name: String) throws {
        let help = try runAs(name, ["--help"])
        #expect(help.exit == 0)
        #expect(help.stdout.contains("USAGE: \(name) <subcommand>"))

        let subcommandHelp = try runAs(name, ["add", "--help"])
        #expect(subcommandHelp.stdout.contains("USAGE: \(name) add"))
    }

    @Test("an unknown subcommand points at the invoked binary",
          arguments: ["remctl", "rctl", "reminders"])
    func unknownSubcommandNamesBinary(name: String) throws {
        let result = try runAs(name, ["no-such-command"])
        #expect(result.exit != 0)
        #expect(result.stderr.contains("Usage: \(name) <subcommand>"))
        #expect(result.stderr.contains("See '\(name) --help'"))
    }

    @Test("completion scripts are generated for the invoked binary",
          arguments: ["remctl", "rctl", "reminders"])
    func completionNamesBinary(name: String) throws {
        let zsh = try runAs(name, ["completion", "zsh"])
        #expect(zsh.exit == 0)
        #expect(zsh.stdout == CompletionScripts.script(.zsh, commandName: name))

        let bash = try runAs(name, ["completion", "bash"])
        #expect(bash.stdout == CompletionScripts.script(.bash, commandName: name))

        let fish = try runAs(name, ["completion", "fish"])
        #expect(fish.stdout == CompletionScripts.script(.fish, commandName: name))
    }

    @Test("--version prints the bare version under every name",
          arguments: ["remctl", "rctl", "reminders"])
    func versionUnderEveryName(name: String) throws {
        let result = try runAs(name, ["--version"])
        #expect(result.exit == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == remctlVersion)
    }

    @Test("an unknown binary name falls back to remctl")
    func unknownBinaryNameFallsBack() throws {
        let help = try runAs("remindersctl", ["--help"])
        #expect(help.stdout.contains("USAGE: remctl <subcommand>"))

        let completion = try runAs("remindersctl", ["completion", "zsh"])
        #expect(completion.stdout == CompletionScripts.zsh)
    }
}
