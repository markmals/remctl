import Testing
import Foundation
@testable import RemindersControl

/// A box for the prompt a `@Sendable` confirmation closure was shown.
final class Prompted: @unchecked Sendable {
    var value = ""
}

/// Stdin seams for the destructive-confirmation tests.
extension ConfirmationPrompt {
    /// An interactive terminal whose user types `answer`.
    static func answering(_ answer: String) -> ConfirmationPrompt {
        ConfirmationPrompt(isInteractive: { true }, ask: { _ in answer })
    }

    /// An interactive terminal that hands the prompt it showed to `seen`, then answers `answer`.
    static func recording(_ seen: @escaping @Sendable (String) -> Void, answer: String = "y") -> ConfirmationPrompt {
        ConfirmationPrompt(isInteractive: { true }, ask: { prompt in seen(prompt); return answer })
    }

    /// A terminal that must never be asked (the caller passed --force).
    static let unexpected = ConfirmationPrompt(
        isInteractive: { true },
        ask: { _ in Issue.record("should not prompt with --force"); return "n" })

    /// Stdin is a pipe or redirect: nothing can be answered.
    static let nonInteractive = ConfirmationPrompt(isInteractive: { false }, ask: { _ in nil })

    /// An interactive terminal where input ends before an answer arrives.
    static let endOfInput = ConfirmationPrompt(isInteractive: { true }, ask: { _ in nil })
}
