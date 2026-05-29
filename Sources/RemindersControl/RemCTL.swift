import ArgumentParser

/// Root command for the `remctl` CLI. Subcommand groups are assembled in
/// `allSubcommands`; each group lives in its own file under `Commands/`.
public struct RemCTL: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "remctl",
        abstract: "Power-user CLI for Apple Reminders.",
        version: remctlVersion,
        subcommands: allSubcommands
    )
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
