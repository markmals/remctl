import Foundation
import ReminderKitPrivate

/// The synced rich-link URL rule from upstream `validate_private_args` / `parse_subtask_specs`:
/// an http(s) URL whose host resolves only to public addresses. ReminderKitPrivate enforces the
/// same policy (`RKPLooksLikeWebURL`) when it saves the link; checking first, before any write,
/// keeps a refused link from failing after its reminder already exists.
enum RichLinkURL {
    /// nil when `url` can become a synced rich link; otherwise the refusal, naming `flag`.
    static func problem(_ url: String, flag: String) -> String? {
        guard isWebURL(url) else { return "\(flag) requires an http or https URL." }
        guard RKPLooksLikeWebURL(url) else { return "\(flag) must resolve to a public http or https host." }
        return nil
    }

    /// Port of `is_web_url`: http or https scheme with a non-empty host.
    private static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
