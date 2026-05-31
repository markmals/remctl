import ArgumentParser

/// Root command for the `remctl` CLI. Subcommand groups are assembled in
/// `allSubcommands`; each group lives in its own file under `Commands/`.
public struct RemindersControl: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "remctl",
        abstract: "Power-user CLI for Apple Reminders.",
        version: remctlVersion,
        subcommands: allSubcommands
    )

    /// Entry point. Normalizes argv before delegating to ArgumentParser so the
    /// `list-symbols --html` flag can be value-OPTIONAL — argparse's
    /// `nargs='?' const=''` (remctl:7831) — which ArgumentParser cannot express on
    /// a single option. A bare `--html` (last token or directly followed by another
    /// `--option`) gets an explicit empty-string value injected.
    public static func main() async {
        await main(normalizeListSymbolsHTMLArgs(Array(CommandLine.arguments.dropFirst())))
    }

    /// If the args are a `list-symbols` invocation containing a bare `--html` (i.e.
    /// not already followed by a value), insert `""` after it so it maps to the
    /// default-path / const='' case. Idempotent and conservative: leaves `--html PATH`,
    /// `--html=PATH`, and non-`list-symbols` invocations untouched.
    static func normalizeListSymbolsHTMLArgs(_ args: [String]) -> [String] {
        guard args.first == "list-symbols" else { return args }
        var out: [String] = []
        var i = 0
        while i < args.count {
            let tok = args[i]
            out.append(tok)
            if tok == "--html" {
                let next = i + 1 < args.count ? args[i + 1] : nil
                // A bare flag is one with no following token, or one whose next token
                // is another option (starts with "-"). Inject the const='' value.
                if next == nil || next!.hasPrefix("-") {
                    out.append("")
                }
            }
            i += 1
        }
        return out
    }
}

/// Every subcommand type, assembled from the per-group arrays. Populated across
/// Tasks 4–9; starts empty so the package builds after this task.
let allSubcommands: [ParsableCommand.Type] =
    readCommands
    + writeCommands
    + listCommands
    + smartListCommands
    + templateCommands
    + opsCommands
