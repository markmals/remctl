import Foundation

/// How a destructive command asks for confirmation. Production talks to the real terminal; tests
/// substitute both seams.
struct ConfirmationPrompt: Sendable {
    /// Whether stdin is a terminal a human can answer from.
    var isInteractive: @Sendable () -> Bool
    /// Write `prompt` to stderr and read one answer line; nil when input ended before an answer.
    var ask: @Sendable (String) -> String?

    static let standard = ConfirmationPrompt(
        isInteractive: { isatty(STDIN_FILENO) == 1 },
        ask: { prompt in
            FileHandle.standardError.write(Data(prompt.utf8))
            return readLine()
        })
}

/// Port of `confirm_destructive_action` (remctl:194). Returns nil when the caller may proceed, or
/// the outcome to emit instead.
///
/// The prompt goes to stderr so `--json` stdout stays parseable, and a non-interactive caller is
/// refused rather than blocked on a read that will never be answered: under `--json`, or with a
/// non-TTY stdin, `--force` is required.
/// `prompt` is lazy: a `--force` or non-interactive caller never builds it (nor reads the row it
/// usually names).
func confirmDestructiveAction(
    force: Bool, json: Bool, prompt: @autoclosure () -> String, identifier: JSONValue? = nil,
    cancelMessage: String = "Cancelled.", using prompter: ConfirmationPrompt
) -> WriteOutcome? {
    if force { return nil }

    if json || !prompter.isInteractive() {
        let message = "Refusing to continue without --force when --json is used or stdin is not interactive."
        guard json else { return WriteOutcome(stderr: "Error: \(message)\n", exitCode: 1) }
        var pairs: [(String, JSONValue)] = [
            ("status", .string("error")),
            ("code", .string("confirmation_required")),
            ("message", .string(message)),
        ]
        if let identifier { pairs.append(("id", identifier)) }
        return WriteOutcome(stderr: JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n", exitCode: 1)
    }

    guard let answer = prompter.ask(prompt()) else {
        return WriteOutcome(stderr: "Error: confirmation input ended before an answer was received.\n", exitCode: 1)
    }
    if ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return nil }
    return .ok(cancelMessage + "\n")
}
