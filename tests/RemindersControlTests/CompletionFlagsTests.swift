import Testing
import Foundation
import ArgumentParser
@testable import RemindersControl

/// Every option a completion script offers must be one the parser accepts. A stale entry
/// (such as upstream's `--private`, which the Swift port never had) completes to an
/// "Unknown option" error.
@Suite struct CompletionFlagsTests {
    @Test(arguments: ["bash", "zsh", "fish"])
    func everyOfferedOptionParses(shell: String) throws {
        let offers = try Self.offers(shell)
        #expect(offers.count > 100, "parsed too few \(shell) entries; the extractor no longer matches the script")
        let rejected = offers.filter { Self.isUnknownOption(command: $0.command, option: $0.option) }
        #expect(rejected.isEmpty, "\(shell) offers options the parser rejects: \(rejected.map { "\($0.command) \($0.option)" })")
    }

    private struct Offer { let command: String; let option: String }

    private static func offers(_ shell: String) throws -> [Offer] {
        switch shell {
        case "bash": return try bashOffers()
        case "zsh": return try zshOffers()
        default: return try fishOffers()
        }
    }

    /// ArgumentParser reports a missing or invalid positional before an unknown option, so try
    /// the option behind zero, one and two placeholder positionals ("1" also satisfies Int
    /// positionals); a known option never reads as unknown.
    private static func isUnknownOption(command: String, option: String) -> Bool {
        let shapes = [[command, option], [command, "1", option], [command, "1", "1", option]]
        return shapes.contains { arguments in
            do {
                _ = try RemindersControl.parseAsRoot(arguments)
                return false
            } catch {
                return RemindersControl.message(for: error).contains("Unknown option '\(option)'")
            }
        }
    }

    /// `[ "$cmd" = "x" ] || [ "$cmd" = "y" ]; then COMPREPLY=( $(compgen -W "…" …) )`
    private static func bashOffers() throws -> [Offer] {
        let entry = try NSRegularExpression(
            pattern: #"((?:\[ "\$cmd" = "[a-z-]+" \](?: \|\| )?)+); then\n\s*COMPREPLY=\( \$\(compgen -W "([^"]*)""#)
        let commandName = try NSRegularExpression(pattern: #""\$cmd" = "([a-z-]+)""#)
        let script = CompletionScripts.bash
        return matches(entry, in: script).flatMap { groups -> [Offer] in
            let commands = matches(commandName, in: groups[1]).map { $0[1] }
            let options = groups[2].split(separator: " ").map(String.init).filter { $0.hasPrefix("--") }
            return commands.flatMap { command in options.map { Offer(command: command, option: $0) } }
        }
    }

    /// `        add)` opens a block of `'--flag[…]'` / `{-t,--tags}'[…]'` specs ending at `;;`.
    private static func zshOffers() throws -> [Offer] {
        let label = try NSRegularExpression(pattern: #"^        ([a-z][a-z|-]*)\)$"#)
        let option = try NSRegularExpression(pattern: #"(?:'|,)(--[a-z][a-z-]*)(?:\[|\})"#)
        var offers: [Offer] = []
        var commands: [String] = []
        for line in CompletionScripts.zsh.split(separator: "\n").map(String.init) {
            if let groups = matches(label, in: line).first {
                commands = groups[1].split(separator: "|").map(String.init)
            } else if line.trimmingCharacters(in: .whitespaces) == ";;" {
                commands = []
            } else {
                for groups in matches(option, in: line) {
                    offers += commands.map { Offer(command: $0, option: groups[1]) }
                }
            }
        }
        return offers
    }

    /// `complete -c remctl -n "__fish_seen_subcommand_from x y" … -l name …`
    private static func fishOffers() throws -> [Offer] {
        let entry = try NSRegularExpression(
            pattern: #"__fish_seen_subcommand_from ([a-z -]+)" .*?-l ([a-z][a-z-]*)"#)
        return matches(entry, in: CompletionScripts.fish).flatMap { groups in
            groups[1].split(separator: " ").map { Offer(command: String($0), option: "--" + groups[2]) }
        }
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
