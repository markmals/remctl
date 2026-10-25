import Foundation
import GRDB

/// Port of `effective_section_memberships` (upstream 231fb1f, c6b13c4): the section each member of
/// a REMMemberships record is effectively in, keyed by the member's first-seen identifier. Members
/// in no section are left out.
///
/// ReminderKit keeps one membership per member; when two entries disagree, its merge keeps the
/// newest `modifiedOn`, and a newest obsolete entry means "no section". When dates cannot order a
/// disagreement, `strict` callers (write verification) get no section rather than a guess, while
/// display keeps the last live entry, as RemCTL always has.
func effectiveSectionMemberships(_ entries: [[String: Any]], strict: Bool) -> [String: String] {
    var order: [String] = []
    var byMember: [String: [[String: Any]]] = [:]
    for entry in entries {
        guard let member = entry["memberID"] as? String, !member.isEmpty else { continue }
        let key = unicodeCasefold(member)
        if byMember[key] == nil { order.append(key) }
        byMember[key, default: []].append(entry)
    }
    var resolved: [String: String] = [:]
    for key in order {
        guard let group = effectiveGroup(byMember[key] ?? [], strict: strict),
              let member = byMember[key]?.first?["memberID"] as? String else { continue }
        resolved[member] = group
    }
    return resolved
}

private func liveGroup(_ entry: [String: Any]) -> String? {
    guard let group = entry["groupID"] as? String, !group.isEmpty,
          (entry["isObsolete"] as? NSNumber)?.boolValue != true else { return nil }
    return group
}

private func agree(_ entries: [[String: Any]]) -> Bool {
    Set(entries.map { unicodeCasefold(liveGroup($0) ?? "") }).count == 1
}

/// `modifiedOn` as a number; booleans are not dates.
private func modifiedOn(_ entry: [String: Any]) -> Double? {
    guard let number = entry["modifiedOn"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.doubleValue
}

private func effectiveGroup(_ entries: [[String: Any]], strict: Bool) -> String? {
    func undecided(_ candidates: [[String: Any]]) -> String? {
        strict ? nil : candidates.reversed().lazy.compactMap(liveGroup).first
    }
    var entries = entries
    if !agree(entries) {
        let dates = entries.map(modifiedOn)
        guard dates.allSatisfy({ $0 != nil }), let newestDate = dates.compactMap({ $0 }).max() else {
            return undecided(entries)
        }
        let newest = zip(entries, dates).filter { $0.1 == newestDate }.map(\.0)
        guard agree(newest) else { return undecided(newest) }
        entries = newest
    }
    return entries.last.flatMap(liveGroup)
}

extension RemindersStore {
    /// The `memberships` entries of a list's (or custom smart list's) section-membership record;
    /// empty when the row, column, or payload is missing or unreadable.
    func sectionMembershipEntries(pk: Int) -> [[String: Any]] {
        guard let row = try? queue.read({ try Row.fetchOne($0, sql:
                  "SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST WHERE Z_PK = ?", arguments: [pk]) }),
              let text = row.blobString("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let memberships = object["memberships"] as? [Any] else { return [] }
        return memberships.compactMap { $0 as? [String: Any] }
    }
}
