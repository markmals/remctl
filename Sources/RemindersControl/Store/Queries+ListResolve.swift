import GRDB
import Foundation

// Shared list / smart-list resolution + ckid lookups used by list-edit, list-pin/unpin,
// list-create, and smart-list-create/edit/delete. The 4-tier name resolver and ckid Z_ENT
// discrimination are ports of resolve_list_ref/resolve_smart_list_ref/q_list_ckid/
// q_smart_list_ckid (remctl:803/891/958/967). The regular-list resolver and the
// `normalizeListLookupName` / `unicodeCasefold` helpers live in Queries+Lists.swift.

extension RemindersStore {
    /// q_smart_lists rows, minimal columns for name resolution. ORDER BY ZNAME-ish then Z_PK.
    /// Mirrors the smart-list filter (Z_ENT=4 OR ZSMARTLISTTYPE set). Empty if ZSMARTLISTTYPE absent.
    func smartListsForResolution() -> [Row] {
        let t = tableColumnNames("ZREMCDBASELIST")
        guard t.contains("ZSMARTLISTTYPE") else { return [] }
        let sql = "SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE FROM ZREMCDBASELIST "
            + "WHERE ZMARKEDFORDELETION = 0 AND (Z_ENT = 4 OR ZSMARTLISTTYPE IS NOT NULL) "
            + "ORDER BY COALESCE(ZNAME, ''), Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }

    /// Port of resolve_smart_list_ref (remctl:891): by id (tier0), or 4-tier name match
    /// (exact → casefold → NFKC-normalized), each uniqueness-checked. Display name comes from
    /// smartListDisplayName (ZNAME or the type-derived fallback), matching the Python.
    public func resolveSmartListRef(name: String?, smartListId: Int?) -> ListResolution {
        let rows = smartListsForResolution()
        func found(_ r: Row) -> ListResolution {
            .found(id: r.int("Z_PK") ?? 0, title: smartListDisplayName(r), objectUUID: r.string("ZCKIDENTIFIER"))
        }
        func candidates(_ rs: [Row]) -> ListResolution {
            .ambiguous(candidates: rs.map { (id: $0.int("Z_PK") ?? 0, title: smartListDisplayName($0)) })
        }
        if let smartListId {
            let matches = rows.filter { $0.int("Z_PK") == smartListId }
            return matches.isEmpty ? .notFound : found(matches[0])
        }
        guard let name, !name.isEmpty else { return .notFound }
        // tier 1: exact display name
        let exact = rows.filter { smartListDisplayName($0) == name }
        if exact.count == 1 { return found(exact[0]) }
        if exact.count > 1 { return candidates(exact) }
        // tier 2: casefold (Python str.casefold())
        let folded = unicodeCasefold(name)
        let ci = rows.filter { unicodeCasefold(smartListDisplayName($0)) == folded }
        if ci.count == 1 { return found(ci[0]) }
        if ci.count > 1 { return candidates(ci) }
        // tier 3: NFKC-normalized
        let normalized = normalizeListLookupName(name)
        if normalized.isEmpty { return .notFound }
        let nm = rows.filter { normalizeListLookupName(smartListDisplayName($0)) == normalized }
        if nm.count == 1 { return found(nm[0]) }
        if nm.count > 1 { return candidates(nm) }
        return .notFound
    }

    /// q_list_ckid (remctl:958): the regular list's CloudKit identifier (Z_ENT=3 only,
    /// not deleted). NULL or empty → nil.
    public func listCkid(pk: Int) -> String? {
        let row = try? queue.read { try Row.fetchOne($0, sql:
            "SELECT ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3",
            arguments: [pk]) }
        guard let ckid = row?.string("ZCKIDENTIFIER"), !ckid.isEmpty else { return nil }
        return ckid
    }

    /// q_smart_list_ckid (remctl:967): the smart list's CloudKit identifier
    /// (Z_ENT=4 OR ZSMARTLISTTYPE set, not deleted). NULL or empty → nil.
    public func smartListCkid(pk: Int) -> String? {
        let row = try? queue.read { try Row.fetchOne($0, sql:
            "SELECT ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND (Z_ENT = 4 OR ZSMARTLISTTYPE IS NOT NULL)",
            arguments: [pk]) }
        guard let ckid = row?.string("ZCKIDENTIFIER"), !ckid.isEmpty else { return nil }
        return ckid
    }

    /// Whether a smart list is a custom (user-authored) one rather than a built-in Reminders smart
    /// list. The two kinds need different ReminderKit fetches when pinning (upstream 76a95ce).
    public func smartListIsCustom(pk: Int) -> Bool {
        let row = try? queue.read { try Row.fetchOne($0, sql:
            "SELECT ZSMARTLISTTYPE FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0",
            arguments: [pk]) }
        return row?.string("ZSMARTLISTTYPE") == Constants.customSmartListType
    }

    /// q_custom_smart_list_exact_name_count (remctl:507): live custom smart lists with this
    /// EXACT name (case-sensitive). Used to reject duplicate smart-list-create.
    public func customSmartListExactNameCount(name: String) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND ZNAME = ?",
            arguments: [Constants.customSmartListType, name]) ?? 0 }) ?? 0
    }

    /// q_list_ids_named (remctl:1719): the Z_PKs of every live regular list with this EXACT name.
    /// `list-create` compares the set before and after the write to learn the new list's id.
    public func listIdsNamed(_ name: String) -> Set<Int> {
        let rows = (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME = ?",
            arguments: [name]) }) ?? []
        return Set(rows.compactMap { $0.int("Z_PK") })
    }

    /// q_custom_smart_list_delete_matches name-path (remctl:515): live custom smart lists with
    /// this EXACT name, ORDER BY Z_PK. Used by smart-list edit/delete to locate the target.
    public func customSmartListMatches(name: String) -> [(pk: Int, name: String, ckid: String?)] {
        let rows = (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND ZNAME = ? ORDER BY Z_PK",
            arguments: [Constants.customSmartListType, name]) }) ?? []
        return rows.map { (pk: $0.int("Z_PK") ?? 0, name: $0.string("ZNAME") ?? "", ckid: $0.string("ZCKIDENTIFIER")) }
    }

    /// q_custom_smart_list_delete_matches id-path (remctl:516): the live custom smart list with this
    /// exact Z_PK. Used by smart-list edit/delete when `--smart-list-id` is supplied.
    public func customSmartListMatches(smartListId: Int) -> [(pk: Int, name: String, ckid: String?)] {
        let rows = (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND Z_PK = ?",
            arguments: [Constants.customSmartListType, smartListId]) }) ?? []
        return rows.map { (pk: $0.int("Z_PK") ?? 0, name: $0.string("ZNAME") ?? "", ckid: $0.string("ZCKIDENTIFIER")) }
    }
}

/// A smart list named by `--smart-list`/`--smart-list-id`.
public struct SmartListTarget {
    public let id: Int
    public let title: String
    public let objectUUID: String?
    public let isCustom: Bool
}

/// Port of `resolve_smart_list_or_die`: a smart list by name (exact → case-insensitive →
/// normalized) or numeric id, built-in or custom. Failures carry the codes commands report under
/// `--json`; callers decide what a built-in smart list means for them.
public func resolveSmartListTarget(store: RemindersStore, name: String?, smartListId: Int?) throws -> SmartListTarget {
    if name != nil && smartListId != nil {
        throw CLIError("pass either --smart-list or --smart-list-id, not both.", code: "invalid_smart_list_target")
    }
    let requested = smartListId.map { "id \($0)" } ?? name ?? ""
    switch store.resolveSmartListRef(name: name, smartListId: smartListId) {
    case .found(let id, let title, let uuid), .group(let id, let title, let uuid, _):
        return SmartListTarget(id: id, title: title, objectUUID: uuid.flatMap { $0.isEmpty ? nil : $0 },
                               isCustom: store.smartListIsCustom(pk: id))
    case .ambiguous(let candidates):
        let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
        throw CLIError("multiple smart lists match \(WriteFormatting.pyRepr(requested)). "
                       + "Use the exact smart-list name or --smart-list-id with one of: \(options)", code: "smart_list_ambiguous")
    case .notFound:
        throw CLIError("smart list not found: \(requested)", code: "smart_list_not_found")
    }
}
