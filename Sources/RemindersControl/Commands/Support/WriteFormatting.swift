import Foundation

/// Shared write-command formatting/resolution helpers, hoisted from the per-command
/// `private static` duplicates in `Add` and `Edit`. Single source of truth so the two
/// commands stay in lockstep with the Python `resolve_list_ref` / `{value!r}` semantics.
enum WriteFormatting {
    /// Python `repr()` of a string for error messages: single-quoted, with `'` and `\` escaped.
    /// Mirrors the `{value!r}` formatting in `fail_invalid_due_date` / `fail_invalid_recurrence`.
    static func pyRepr(_ s: String) -> String {
        if s.contains("'") && !s.contains("\"") {
            return "\"\(s)\""
        }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    /// Determine which match tier `resolveListRef` used, to reproduce the `method` field that
    /// the Python `resolve_list_ref` returns (Swift's `ListResolution.found` does not carry it).
    /// `--list-id` always resolves by id. For a name, recompute the comparison against the
    /// resolved title (exact → case_insensitive → normalized).
    static func resolveMethod(store: RemindersStore, name: String?, listId: Int?, resolvedTitle: String) -> String {
        if listId != nil { return "id" }
        guard let name else { return "exact" }
        if resolvedTitle == name { return "exact" }
        if resolvedTitle.lowercased() == name.lowercased() { return "case_insensitive" }
        return "normalized"
    }
}
