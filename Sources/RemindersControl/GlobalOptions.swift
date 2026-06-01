import ArgumentParser

/// The version string surfaced by `remctl --version`. The Swift rewrite starts a
/// fresh 0.x line (not yet API-stable); bump here on release.
public let remctlVersion = "0.1.1"

/// Shared output options included by every subcommand. Parity note: the Python
/// CLI adds `--json` per-subcommand (via `js(c)`), not as a root-level flag, so
/// it lives in an option group each command embeds rather than on the root.
public struct JSONOptions: ParsableArguments {
    public init() {}

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.")
    public var json = false
}

/// Thrown by Phase-0 stubs. The real implementations land in later phases.
struct NotImplemented: Error, CustomStringConvertible {
    let command: String
    init(_ command: String) { self.command = command }
    var description: String { "`\(command)` is not implemented yet (Phase 0 stub)." }
}
