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

    /// q_custom_smart_list_exact_name_count (remctl:507): live custom smart lists with this
    /// EXACT name (case-sensitive). Used to reject duplicate smart-list-create.
    public func customSmartListExactNameCount(name: String) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND ZNAME = ?",
            arguments: [Constants.customSmartListType, name]) ?? 0 }) ?? 0
    }

    /// q_custom_smart_list_delete_matches name-path (remctl:515): live custom smart lists with
    /// this EXACT name, ORDER BY Z_PK. Used by smart-list edit/delete to locate the target.
    public func customSmartListMatches(name: String) -> [(pk: Int, name: String, ckid: String?)] {
        let rows = (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND ZNAME = ? ORDER BY Z_PK",
            arguments: [Constants.customSmartListType, name]) }) ?? []
        return rows.map { (pk: $0.int("Z_PK") ?? 0, name: $0.string("ZNAME") ?? "", ckid: $0.string("ZCKIDENTIFIER")) }
    }
}
