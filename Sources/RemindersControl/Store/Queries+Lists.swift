import GRDB
import Foundation

/// Outcome of resolving a list reference (mirrors resolve_list_ref).
public enum ListResolution {
    case found(id: Int, title: String, objectUUID: String?)
    case ambiguous(candidates: [(id: Int, title: String)])
    case notFound
}

extension RemindersStore {
    /// q_lists, minimal columns for name resolution. ORDER BY ZNAME (binary), Z_ENT=3, named only.
    func listsForResolution() -> [Row] {
        (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' ORDER BY ZNAME") }) ?? []
    }

    func listByPkForResolution(_ id: Int) -> Row? {
        try? queue.read { try Row.fetchOne($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''",
            arguments: [id]) }
    }

    /// Port of resolve_list_ref: by id, or 4-tier name match (exact → casefold → normalized).
    public func resolveListRef(name: String?, listId: Int?) -> ListResolution {
        if let listId {
            guard let row = listByPkForResolution(listId) else { return .notFound }
            return .found(id: row.int("Z_PK") ?? listId, title: row.string("ZNAME") ?? "", objectUUID: row.string("ZCKIDENTIFIER"))
        }
        guard let name, !name.isEmpty else { return .notFound }
        let rows = listsForResolution()
        func found(_ r: Row) -> ListResolution {
            .found(id: r.int("Z_PK") ?? 0, title: r.string("ZNAME") ?? "", objectUUID: r.string("ZCKIDENTIFIER"))
        }
        func candidates(_ rs: [Row]) -> ListResolution {
            .ambiguous(candidates: rs.map { (id: $0.int("Z_PK") ?? 0, title: $0.string("ZNAME") ?? "") })
        }
        // tier 1: exact
        let exact = rows.filter { $0.string("ZNAME") == name }
        if exact.count == 1 { return found(exact[0]) }
        if exact.count > 1 { return candidates(exact) }
        // tier 2: case-insensitive
        let folded = name.lowercased()
        let ci = rows.filter { ($0.string("ZNAME") ?? "").lowercased() == folded }
        if ci.count == 1 { return found(ci[0]) }
        if ci.count > 1 { return candidates(ci) }
        // tier 3: normalized
        let normalized = normalizeListLookupName(name)
        if normalized.isEmpty { return .notFound }
        let nm = rows.filter { normalizeListLookupName($0.string("ZNAME") ?? "") == normalized }
        if nm.count == 1 { return found(nm[0]) }
        if nm.count > 1 { return candidates(nm) }
        return .notFound
    }
}

extension RemindersStore {
    /// Dynamic column set for q_lists (mirrors list_select_columns).
    func listSelectColumns() -> [String] {
        var cols = ["Z_PK", "ZNAME", "ZCKIDENTIFIER"]
        let t = tableColumnNames("ZREMCDBASELIST")
        for c in ["ZBADGEEMBLEM", "ZCOLOR", "ZISPINNEDBYCURRENTUSER", "ZPINNEDDATE",
                  "ZSHOULDCATEGORIZEGROCERYITEMS", "ZSHOULDAUTOCATEGORIZEITEMS",
                  "ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST", "ZGROCERYLOCALEID",
                  "ZAUTOCATEGORIZATIONLOCALCORRECTIONSCHECKSUM"] where t.contains(c) {
            cols.append(c)
        }
        if t.contains("ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA") {
            cols.append("length(ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA) AS ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA_LENGTH")
        }
        return cols
    }

    /// q_lists: named user lists (Z_ENT=3), ORDER BY ZNAME (binary).
    public func lists() -> [Row] {
        let cols = listSelectColumns().joined(separator: ", ")  // OUTSIDE the read (reentrancy)
        let sql = "SELECT \(cols) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' ORDER BY ZNAME"
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }

    /// Count of live sections for a list (q_sections list_pk count, for the human lists view).
    public func sectionCountForList(_ pk: Int) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ?", arguments: [pk]) ?? 0 }) ?? 0
    }
}

/// Port of normalize_list_lookup_name: NFKC + casefold, keep alnum, collapse mark/punct/symbol/space
/// runs to a single space, strip. (Swift `lowercased()` approximates Python `casefold()`; Character
/// classes approximate Unicode categories M/P/S/Z — sufficient for realistic list names.)
public func normalizeListLookupName(_ name: String) -> String {
    if name.isEmpty { return "" }
    let text = name.precomposedStringWithCompatibilityMapping.lowercased()
    var parts: [Character] = []
    var lastSpace = false
    for ch in text {
        if ch.isLetter || ch.isNumber {
            parts.append(ch); lastSpace = false
        } else if ch.isWhitespace || ch.isPunctuation || ch.isSymbol {
            if !parts.isEmpty && !lastSpace { parts.append(" "); lastSpace = true }
        }
    }
    return String(parts).trimmingCharacters(in: .whitespaces)
}

extension RemindersStore {
    /// q_sections(list_pk): a list's sections, ordered by Z_PK.
    public func sectionsForList(_ pk: Int) -> [Row] {
        (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ? ORDER BY Z_PK", arguments: [pk]) }) ?? []
    }

    /// q_section_memberships: reminder ZCKIDENTIFIER -> section ZDISPLAYNAME (from the list membership blob).
    public func sectionMemberships(_ pk: Int) -> [String: String] {
        let blobRow = try? queue.read { try Row.fetchOne($0, sql:
            "SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST WHERE Z_PK = ?", arguments: [pk]) }
        guard let blob = blobRow?.blobString("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA"),
              let data = blob.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memberships = obj["memberships"] as? [[String: Any]] else { return [:] }
        // section ckid -> display name (separate read, sequential — not nested)
        let secRows = (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT ZCKIDENTIFIER, ZDISPLAYNAME FROM ZREMCDBASESECTION WHERE ZLIST = ? AND ZMARKEDFORDELETION = 0", arguments: [pk]) }) ?? []
        var g2n: [String: String] = [:]
        for r in secRows { if let ck = r.string("ZCKIDENTIFIER") { g2n[ck] = r.string("ZDISPLAYNAME") } }
        var result: [String: String] = [:]
        for m in memberships {
            guard let groupID = m["groupID"] as? String, let memberID = m["memberID"] as? String,
                  let name = g2n[groupID] else { continue }
            result[memberID] = name
        }
        return result
    }

    /// Whether a list (by Z_PK) is a grocery list.
    public func listIsGroceries(_ pk: Int) -> Bool {
        ((try? queue.read { try Int.fetchOne($0, sql:
            "SELECT ZSHOULDCATEGORIZEGROCERYITEMS FROM ZREMCDBASELIST WHERE Z_PK = ?", arguments: [pk]) }) ?? nil ?? 0) != 0
    }
}

/// Command-level helper mirroring resolve_required_list_target_or_die — throws CLIError
/// (Dispatch.runRead prints "Error: <msg>" + exit 1). Returns the resolved list.
public func resolveRequiredListTarget(store: RemindersStore, name: String?, listId: Int?) throws -> (id: Int, title: String, objectUUID: String?) {
    if name == nil && listId == nil {
        throw CLIError("pass a list name or --list-id.")
    }
    if name != nil && listId != nil {
        throw CLIError("pass either a list name or --list-id, not both.")
    }
    let requested = listId != nil ? "id \(listId!)" : (name ?? "")
    switch store.resolveListRef(name: name, listId: listId) {
    case .found(let id, let title, let uuid):
        return (id, title, uuid)
    case .ambiguous(let candidates):
        let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
        throw CLIError("multiple lists match '\(requested)'. Use the exact list name or --list-id with one of: \(options)")
    case .notFound:
        throw CLIError("list not found: \(requested)")
    }
}
