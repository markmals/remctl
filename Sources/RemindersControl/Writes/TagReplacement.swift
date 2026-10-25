import Foundation

/// A rejected tag-replacement request with a structured JSON error code (upstream c0db904).
public struct TagReplacementError: Error, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }

    public func outcome(json: Bool) -> WriteOutcome {
        if json {
            let payload: JSONValue = .object([
                ("status", .string("error")),
                ("code", .string(code)),
                ("message", .string(message)),
            ])
            return WriteOutcome(stderr: payload.serialized(indent: nil, ensureAscii: true) + "\n", exitCode: 1)
        }
        return .error(message)
    }
}

/// `edit --set-tags` / `--clear-tags` / `--remove-tag`: the synced hashtag set a reminder should
/// end up with (port of `validate_tag_replacement_args` + the replacement block of
/// `apply_private_changes`, upstream c0db904). `-t/--tags` stays additive and the three
/// replacement modes are exclusive with it and with each other.
public enum TagReplacement {

    /// Rejects conflicting or empty requests. Returns nil when the combination is writable.
    /// Callers run this before any write so a refusal never leaves half an edit applied.
    public static func validate(tags: String?, setTags: String?, clearTags: Bool, removeTag: [String]) -> TagReplacementError? {
        let modes = [setTags != nil, clearTags, !removeTag.isEmpty].filter { $0 }.count
        if modes > 0, tags?.isEmpty == false {
            return TagReplacementError(
                code: "tag_replacement_conflicts_with_tags",
                message: "-t/--tags adds synced tags and cannot be combined with --set-tags, --clear-tags, or --remove-tag.")
        }
        if modes > 1 {
            return TagReplacementError(
                code: "conflicting_tag_replacement_modes",
                message: "pass only one of --set-tags, --clear-tags, or --remove-tag.")
        }
        if let setTags, PrivateParsing.splitCSV(setTags).isEmpty {
            return TagReplacementError(
                code: "set_tags_requires_tag",
                message: "--set-tags requires at least one tag. Use --clear-tags to remove all tags.")
        }
        if !removeTag.isEmpty, removeTagValues(removeTag).isEmpty {
            return TagReplacementError(
                code: "remove_tag_requires_tag",
                message: "--remove-tag requires a non-empty tag.")
        }
        return nil
    }

    /// The tag set to write, or nil when no replacement mode was requested. `--remove-tag`
    /// subtracts from the reminder's current tags, matched case-insensitively like upstream's
    /// casefold comparison; the surviving tags keep their stored spelling and order.
    public static func resolve(pk: Int, store: RemindersStore, setTags: String?, clearTags: Bool, removeTag: [String]) -> [String]? {
        if clearTags { return [] }
        if let setTags { return PrivateParsing.dedupeTags(PrivateParsing.splitCSV(setTags)) }
        guard !removeTag.isEmpty else { return nil }
        let drop = Set(removeTagValues(removeTag).map { $0.lowercased() })
        return store.hashtags(pk: pk).filter { !drop.contains($0.lowercased()) }
    }

    /// Port of `remove_tag_values` (remctl:4444): each repeatable `--remove-tag` value is itself
    /// a comma-separated list.
    private static func removeTagValues(_ values: [String]) -> [String] {
        PrivateParsing.dedupeTags(values.flatMap(PrivateParsing.splitCSV))
    }
}
