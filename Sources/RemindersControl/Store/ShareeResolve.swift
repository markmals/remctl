import Foundation
import GRDB

// ──────────────────────────────────────────────────────────────────────────────
// Sharee resolution — port of `resolve_sharee_or_die` /
// `resolve_assignment_originator_or_die` (upstream 683c362), with every CKID
// comparison going through `ckidEq` (the aba7cf5 case-insensitivity fix).
// Errors are CLIError (the command shell prints "Error: <msg>" and exits 1).
// ──────────────────────────────────────────────────────────────────────────────

/// Port of `_sharee_match_terms` (remctl:830): the strings a --assign value may
/// match. Includes the bare address tail ("zelda@example.com" from
/// "mailto:zelda@example.com").
func shareeMatchTerms(_ row: ReminderRow) -> [String] {
    var terms: [String?] = [
        row.string("ZCKIDENTIFIER"),
        row.string("ZDISPLAYNAME"),
        row.string("ZFIRSTNAME"),
        row.string("ZLASTNAME"),
        shareeDisplayName(row),
        row.string("ZADDRESS1"),
    ]
    if let address = row.string("ZADDRESS1"), let colon = address.firstIndex(of: ":") {
        terms.append(String(address[address.index(after: colon)...]))
    }
    return terms.compactMap { $0 }.filter { !$0.isEmpty }
}

/// Port of `resolve_sharee_or_die` (remctl:846). Resolves a --assign value against a
/// shared list's sharees: "me"/"myself" → the list owner; otherwise numeric Z_PK,
/// then exact term match, then contains match; ambiguous/no-match throw with options.
public func resolveSharee(store: RemindersStore, listPk: Int, value: String, allowMe: Bool = true) throws -> Row {
    let sharees = store.sharees(listPk: listPk)
    guard !sharees.isEmpty else {
        throw CLIError("target list has no sharees; assignment requires a shared list.")
    }
    let currentUserCkid = store.listSharedOwnerCkid(listPk: listPk)
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
        throw CLIError("--assign requires a name, email, phone number, or sharee ID.")
    }
    if allowMe, ["me", "myself"].contains(unicodeCasefold(raw)) {
        guard let currentUserCkid else {
            throw CLIError("could not identify the current-user sharee for this list.")
        }
        for sharee in sharees where ckidEq(sharee.string("ZCKIDENTIFIER"), currentUserCkid) {
            return sharee
        }
        throw CLIError("current-user sharee is not present in this list.")
    }

    let needle = normalizeListLookupName(raw)
    var exact: [Row] = []
    var contains: [Row] = []
    for sharee in sharees {
        if let pk = sharee.int("Z_PK"), String(pk) == raw {
            exact.append(sharee)
            continue
        }
        for term in shareeMatchTerms(sharee) {
            let normalized = normalizeListLookupName(term)
            if normalized == needle {
                exact.append(sharee)
                break
            }
            if !needle.isEmpty && normalized.contains(needle) {
                contains.append(sharee)
                break
            }
        }
    }
    let matches = exact.isEmpty ? contains : exact
    var unique: [Row] = []
    var seen = Set<Int>()
    for sharee in matches {
        let pk = sharee.int("Z_PK") ?? -1
        if !seen.contains(pk) {
            unique.append(sharee)
            seen.insert(pk)
        }
    }
    if unique.count == 1 { return unique[0] }
    if unique.count > 1 {
        let options = unique.map { item in
            let fallback = item.string("ZADDRESS1").flatMap { $0.isEmpty ? nil : $0 }
                ?? item.string("ZCKIDENTIFIER") ?? ""
            return "\(shareeDisplayName(item)) (\(fallback))"
        }.joined(separator: ", ")
        throw CLIError("multiple sharees match \(WriteFormatting.pyRepr(raw)). Use one of: \(options)")
    }
    let options = sharees.map { item -> String in
        let name = shareeDisplayName(item)
        return name.isEmpty ? (item.string("ZCKIDENTIFIER") ?? "") : name
    }.joined(separator: ", ")
    throw CLIError("no sharee matching \(WriteFormatting.pyRepr(raw)) in this list. Available: \(options)")
}

/// Port of `resolve_assignment_originator_or_die` (remctl:909): the current user's
/// own sharee row, used as the assignment originator.
public func resolveAssignmentOriginator(store: RemindersStore, listPk: Int) throws -> Row {
    guard let ownerCkid = store.listSharedOwnerCkid(listPk: listPk) else {
        throw CLIError("could not identify the current-user sharee for assignment originator.")
    }
    for sharee in store.sharees(listPk: listPk) where ckidEq(sharee.string("ZCKIDENTIFIER"), ownerCkid) {
        return sharee
    }
    throw CLIError("current-user sharee is not present in this list.")
}
