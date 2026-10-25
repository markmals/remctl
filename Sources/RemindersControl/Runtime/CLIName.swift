import Foundation

/// The names RemCTL answers to. One binary is installed as `remctl`; `rctl` and
/// `reminders` are symlinks next to it (upstream 5cb595a), so argv[0] is the only
/// signal for which name the user typed. Help, completions, and the hints that tell
/// the user to run a command all follow that name.
public enum CLIName {
    /// The canonical name; also the fallback for an unrecognized argv[0].
    public static let canonical = "remctl"

    /// Every name the CLI answers to, in install order.
    public static let all = [canonical, "rctl", "reminders"]

    /// The name this process was invoked under. Resolved once from argv[0].
    public static let current = resolve(argv0: CommandLine.arguments.first)

    /// Basename of `argv0` when it is one of `all`, else `canonical`. A copy of the
    /// binary under some other name (or an embedding test runner) still calls itself
    /// `remctl` rather than echoing an arbitrary filename back at the user.
    public static func resolve(argv0: String?) -> String {
        guard let argv0, !argv0.isEmpty else { return canonical }
        let name = (argv0 as NSString).lastPathComponent
        return all.contains(name) ? name : canonical
    }
}
