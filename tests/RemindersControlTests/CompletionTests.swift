import Testing
import Foundation
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// CompletionTests – unit tests for `completion` command and shared shell helpers.
//
// Tests are pure (no DB, no filesystem writes): they cover:
//   - Golden byte invariants for the three completion script literals
//   - Cross-shell inconsistency preservation (bash/fish have --date-today-include-past-due, zsh does NOT)
//   - detectShellName / completionTargetPath / resolveSetupShell helpers
//   - completionScript(for:) dispatch + error
//   - CompletionCmd.run() output via FileHandle capture
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct CompletionScriptTests {

    // MARK: - zsh script golden invariants

    @Test("zsh script: non-empty and starts with #compdef remctl")
    func zshStartsWithCompdef() {
        let s = CompletionScripts.zsh
        #expect(!s.isEmpty)
        #expect(s.hasPrefix("#compdef remctl\n"))
    }

    @Test("zsh script: defines _remctl() function")
    func zshDefinesFunction() {
        #expect(CompletionScripts.zsh.contains("_remctl() {"))
    }

    @Test("zsh script: ends with compdef _remctl remctl (+ trailing newline)")
    func zshEndsCorrectly() {
        let s = CompletionScripts.zsh
        #expect(s.hasSuffix("compdef _remctl remctl\n"))
    }

    @Test("zsh script: contains 47 command entries in the commands array")
    func zshCommandCount() {
        // Each entry in the commands=(...) array looks like:
        //     'name:description'
        // They are inside `local -a commands=(` ... `)` and end before `case "$words[2]"`.
        // Find the section between `commands=(` and `)`.
        let s = CompletionScripts.zsh
        guard let start = s.range(of: "local -a commands=(\n"),
              let end = s.range(of: "\n    )\n", range: start.upperBound..<s.endIndex)
        else {
            Issue.record("Could not find commands=(...) block in zsh script")
            return
        }
        let block = String(s[start.upperBound..<end.lowerBound])
        let entries = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(entries.count == 45, "expected 45 command entries, got \(entries.count)")
    }

    @Test("zsh script: does NOT contain --date-today-include-past-due (cross-shell inconsistency preserved)")
    func zshLacksDateTodayIncludePastDue() {
        #expect(!CompletionScripts.zsh.contains("--date-today-include-past-due"))
    }

    // MARK: - bash script golden invariants

    @Test("bash script: non-empty and defines _remctl() function")
    func bashNonEmptyAndDefinesFunction() {
        let s = CompletionScripts.bash
        #expect(!s.isEmpty)
        #expect(s.contains("_remctl() {"))
    }

    @Test("bash script: starts with _remctl function definition")
    func bashStartsWithFunction() {
        #expect(CompletionScripts.bash.hasPrefix("_remctl() {\n"))
    }

    @Test("bash script: ends with complete -F _remctl remctl (+ trailing newline)")
    func bashEndsCorrectly() {
        #expect(CompletionScripts.bash.hasSuffix("complete -F _remctl remctl\n"))
    }

    @Test("bash script: contains --date-today-include-past-due (cross-shell inconsistency preserved)")
    func bashHasDateTodayIncludePastDue() {
        #expect(CompletionScripts.bash.contains("--date-today-include-past-due"))
    }

    @Test("bash script: commands string contains 45 subcommand names")
    func bashCommandCount() {
        // Extract the commands= line
        guard let range = CompletionScripts.bash.range(of: "commands=\""),
              let endRange = CompletionScripts.bash.range(of: "\"", range: range.upperBound..<CompletionScripts.bash.endIndex)
        else {
            Issue.record("Could not find commands= line in bash script")
            return
        }
        let commandsList = String(CompletionScripts.bash[range.upperBound..<endRange.lowerBound])
        let names = commandsList.components(separatedBy: " ").filter { !$0.isEmpty }
        #expect(names.count == 45, "expected 45 bash command names, got \(names.count): \(names)")
    }

    // MARK: - fish script golden invariants

    @Test("fish script: non-empty and starts with # Fish completion for remctl")
    func fishStartsWithComment() {
        let s = CompletionScripts.fish
        #expect(!s.isEmpty)
        #expect(s.hasPrefix("# Fish completion for remctl\n"))
    }

    @Test("fish script: ends with trailing newline")
    func fishEndsWithNewline() {
        #expect(CompletionScripts.fish.hasSuffix("\n"))
    }

    @Test("fish script: contains date-today-include-past-due flag (fish uses -l syntax)")
    func fishHasDateTodayIncludePastDue() {
        // Fish uses '-l date-today-include-past-due' (long option), not '--date-today-include-past-due'
        #expect(CompletionScripts.fish.contains("date-today-include-past-due"))
        #expect(CompletionScripts.fish.contains("-l date-today-include-past-due"))
    }

    @Test("fish script: uses __fish_use_subcommand for subcommand completions")
    func fishUsesSubcommandPredicate() {
        #expect(CompletionScripts.fish.contains("__fish_use_subcommand"))
    }

    @Test("fish script: uses __fish_seen_subcommand_from for per-command flags")
    func fishUsesSeenSubcommandFrom() {
        #expect(CompletionScripts.fish.contains("__fish_seen_subcommand_from"))
    }
}

// MARK: - Cross-shell parity / inconsistency tests

@Suite struct CrossShellInconsistencyTests {

    @Test("bash contains --date-today-include-past-due; zsh does NOT (verbatim inconsistency)")
    func bashHasItZshDoesNot() {
        // bash uses '--date-today-include-past-due' (double-dash form in compgen -W)
        #expect(CompletionScripts.bash.contains("--date-today-include-past-due"))
        #expect(!CompletionScripts.zsh.contains("--date-today-include-past-due"))
    }

    @Test("fish contains date-today-include-past-due; zsh does NOT (verbatim inconsistency)")
    func fishHasItZshDoesNot() {
        // fish uses '-l date-today-include-past-due' (long option form), not the double-dash form
        // zsh _arguments does not include this flag at all
        #expect(CompletionScripts.fish.contains("date-today-include-past-due"))
        #expect(!CompletionScripts.zsh.contains("date-today-include-past-due"))
    }

    @Test("all three scripts end with a newline")
    func allScriptsEndWithNewline() {
        #expect(CompletionScripts.zsh.hasSuffix("\n"), "zsh script missing trailing newline")
        #expect(CompletionScripts.bash.hasSuffix("\n"), "bash script missing trailing newline")
        #expect(CompletionScripts.fish.hasSuffix("\n"), "fish script missing trailing newline")
    }
}

// MARK: - completionScript(for:) dispatch

@Suite struct CompletionScriptDispatchTests {

    @Test("completionScript(for: zsh) returns exact zsh literal")
    func dispatchZsh() throws {
        let result = try completionScript(for: "zsh")
        #expect(result == CompletionScripts.zsh)
    }

    @Test("completionScript(for: bash) returns exact bash literal")
    func dispatchBash() throws {
        let result = try completionScript(for: "bash")
        #expect(result == CompletionScripts.bash)
    }

    @Test("completionScript(for: fish) returns exact fish literal")
    func dispatchFish() throws {
        let result = try completionScript(for: "fish")
        #expect(result == CompletionScripts.fish)
    }

    @Test("completionScript(for: unknown) throws CLIError with expected message")
    func dispatchUnknownThrows() {
        #expect(throws: CLIError.self) {
            _ = try completionScript(for: "tcsh")
        }
    }

    @Test("completionScript(for: unknown) error message contains shell name")
    func dispatchUnknownErrorMessage() {
        do {
            _ = try completionScript(for: "tcsh")
            Issue.record("Expected throw for unsupported shell")
        } catch let e as CLIError {
            #expect(e.message.contains("tcsh"))
            #expect(e.message.contains("Unsupported shell"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - detectShellName

@Suite struct DetectShellNameTests {

    @Test("detectShellName returns basename of SHELL env")
    func returnsBasename() {
        #expect(detectShellName(env: ["SHELL": "/bin/zsh"]) == "zsh")
        #expect(detectShellName(env: ["SHELL": "/bin/bash"]) == "bash")
        #expect(detectShellName(env: ["SHELL": "/usr/local/bin/fish"]) == "fish")
    }

    @Test("detectShellName returns zsh when SHELL is unset")
    func defaultsToZshWhenUnset() {
        #expect(detectShellName(env: [:]) == "zsh")
    }

    @Test("detectShellName returns zsh when SHELL is empty string")
    func defaultsToZshWhenEmpty() {
        #expect(detectShellName(env: ["SHELL": ""]) == "zsh")
    }

    @Test("detectShellName handles tcsh without fallback (just returns basename)")
    func tcshBasename() {
        #expect(detectShellName(env: ["SHELL": "/bin/tcsh"]) == "tcsh")
    }
}

// MARK: - completionTargetPath

@Suite struct CompletionTargetPathTests {

    @Test("zsh target path is ~/.zsh/completions/_remctl")
    func zshTargetPath() throws {
        let env = ["HOME": "/home/test"]
        let url = try completionTargetPath("zsh", env: env)
        #expect(url.path == "/home/test/.zsh/completions/_remctl")
    }

    @Test("bash target path is ~/.local/share/bash-completion/completions/remctl")
    func bashTargetPath() throws {
        let env = ["HOME": "/home/test"]
        let url = try completionTargetPath("bash", env: env)
        #expect(url.path == "/home/test/.local/share/bash-completion/completions/remctl")
    }

    @Test("fish target path is ~/.config/fish/completions/remctl.fish (literal ~/.config, not XDG)")
    func fishTargetPath() throws {
        let env = ["HOME": "/home/test", "XDG_CONFIG_HOME": "/custom/xdg"]
        let url = try completionTargetPath("fish", env: env)
        // Must be literal ~/.config, NOT $XDG_CONFIG_HOME
        #expect(url.path == "/home/test/.config/fish/completions/remctl.fish")
    }

    @Test("fish target path ignores XDG_CONFIG_HOME (uses literal ~/.config)")
    func fishIgnoresXDG() throws {
        let envWithXDG = ["HOME": "/home/test", "XDG_CONFIG_HOME": "/some/other/path"]
        let url = try completionTargetPath("fish", env: envWithXDG)
        #expect(url.path.hasPrefix("/home/test/.config/"))
        #expect(!url.path.hasPrefix("/some/other/path/"))
    }

    @Test("unsupported shell throws CLIError")
    func unsupportedShellThrows() {
        #expect(throws: CLIError.self) {
            _ = try completionTargetPath("tcsh", env: ["HOME": "/home/test"])
        }
    }
}

// MARK: - resolveSetupShell

@Suite struct ResolveSetupShellTests {

    @Test("auto with SHELL=/bin/zsh -> zsh")
    func autoZsh() {
        let result = resolveSetupShell("auto", env: ["SHELL": "/bin/zsh"])
        #expect(result == "zsh")
    }

    @Test("auto with SHELL=/bin/bash -> bash")
    func autoBash() {
        let result = resolveSetupShell("auto", env: ["SHELL": "/bin/bash"])
        #expect(result == "bash")
    }

    @Test("auto with SHELL=/usr/local/bin/fish -> fish")
    func autoFish() {
        let result = resolveSetupShell("auto", env: ["SHELL": "/usr/local/bin/fish"])
        #expect(result == "fish")
    }

    @Test("auto with SHELL=/bin/tcsh -> skip (unsupported shell)")
    func autoTcshReturnsSkip() {
        let result = resolveSetupShell("auto", env: ["SHELL": "/bin/tcsh"])
        #expect(result == "skip")
    }

    @Test("auto with SHELL unset -> zsh (detectShellName default)")
    func autoUnsetShell() {
        let result = resolveSetupShell("auto", env: [:])
        #expect(result == "zsh")
    }

    @Test("skip is returned verbatim")
    func skipPassthrough() {
        let result = resolveSetupShell("skip", env: ["SHELL": "/bin/zsh"])
        #expect(result == "skip")
    }

    @Test("bash is returned verbatim (no detection)")
    func bashPassthrough() {
        let result = resolveSetupShell("bash", env: ["SHELL": "/bin/fish"])
        #expect(result == "bash")
    }

    @Test("zsh is returned verbatim (no detection)")
    func zshPassthrough() {
        let result = resolveSetupShell("zsh", env: ["SHELL": "/bin/bash"])
        #expect(result == "zsh")
    }

    @Test("fish is returned verbatim (no detection)")
    func fishPassthrough() {
        let result = resolveSetupShell("fish", env: ["SHELL": "/bin/zsh"])
        #expect(result == "fish")
    }
}

// MARK: - CompletionCmd integration via CLIRunner

@Suite struct CompletionCmdCLITests {

    @Test("completion zsh outputs exact zsh script")
    func cliCompletionZsh() throws {
        let result = try CLIRunner.run(["completion", "zsh"])
        #expect(result.exit == 0)
        #expect(result.stdout == CompletionScripts.zsh)
        #expect(result.stderr.isEmpty)
    }

    @Test("completion bash outputs exact bash script")
    func cliCompletionBash() throws {
        let result = try CLIRunner.run(["completion", "bash"])
        #expect(result.exit == 0)
        #expect(result.stdout == CompletionScripts.bash)
        #expect(result.stderr.isEmpty)
    }

    @Test("completion fish outputs exact fish script")
    func cliCompletionFish() throws {
        let result = try CLIRunner.run(["completion", "fish"])
        #expect(result.exit == 0)
        #expect(result.stdout == CompletionScripts.fish)
        #expect(result.stderr.isEmpty)
    }

    @Test("completion (no arg) defaults to zsh")
    func cliCompletionDefaultsToZsh() throws {
        let result = try CLIRunner.run(["completion"])
        #expect(result.exit == 0)
        #expect(result.stdout == CompletionScripts.zsh)
    }

    @Test("completion with invalid shell exits non-zero")
    func cliCompletionInvalidShell() throws {
        let result = try CLIRunner.run(["completion", "tcsh"])
        #expect(result.exit != 0)
    }

    @Test("completion output has no double trailing newline (script terminator is preserved)")
    func cliCompletionNoDoubleNewline() throws {
        let result = try CLIRunner.run(["completion", "zsh"])
        #expect(result.exit == 0)
        // The script ends with exactly one \n (the literal's own), not two
        #expect(!result.stdout.hasSuffix("\n\n"))
        #expect(result.stdout.hasSuffix("\n"))
    }
}
