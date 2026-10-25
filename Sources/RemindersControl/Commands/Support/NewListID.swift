import Foundation

/// How `list-create` learns the numeric id of the list it just created. Production reopens the
/// read-only store on every attempt — Reminders writes the row from its own process, so a
/// connection opened earlier can still be showing the state before the create. Tests substitute
/// both seams instead of sleeping.
struct NewListIDLookup: Sendable {
    /// Z_PKs of every live list with this exact name, or nil when the store cannot be read.
    var idsNamed: @Sendable (String) -> Set<Int>?
    /// Wait before the next attempt.
    var wait: @Sendable () async -> Void

    static let standard = NewListIDLookup(
        idsNamed: { name in (try? RemindersStore.open())?.listIdsNamed(name) },
        wait: { try? await Task.sleep(nanoseconds: 250_000_000) })
}

/// Attempts before giving up, a quarter second apart (upstream's `attempts=8`).
private let newListIDAttempts = 8

/// Port of `wait_for_new_list_id` (remctl:1737): the numeric id of a just-created list, once the
/// local store shows it. Comparing the ids before and after the write keeps an older list with the
/// same name from being mistaken for the new one.
///
/// Returns nil when the row never appears, when more than one new row matches, or when the store
/// cannot be read. The list exists in all three cases, so a missing id is reported as a warning
/// and never turns a successful create into a failure.
func waitForNewListID(name: String, before: Set<Int>, using lookup: NewListIDLookup) async -> Int? {
    for attempt in 0..<newListIDAttempts {
        guard let ids = lookup.idsNamed(name) else { return nil }
        let created = ids.subtracting(before)
        if created.count == 1 { return created.first }
        if !created.isEmpty { return nil }
        if attempt < newListIDAttempts - 1 { await lookup.wait() }
    }
    return nil
}
