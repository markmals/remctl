import GRDB
import Foundation

/// Outcome of resolving a list reference (mirrors resolve_list_ref). `.group` is a Reminders
/// list group: a container for lists, not for reminders, so only `show` accepts one.
public enum ListResolution {
    case found(id: Int, title: String, objectUUID: String?)
    case group(id: Int, title: String, objectUUID: String?, children: [(id: Int, title: String)])
    case ambiguous(candidates: [(id: Int, title: String)])
    case notFound
}

extension RemindersStore {
    /// Port of `list_group_filter_sql`: list groups live in ZREMCDBASELIST next to the lists they
    /// contain, so every list read that is not explicitly about groups filters them out. Stores
    /// without the column predate groups and need no filter.
    func listGroupFilterSQL(includeGroups: Bool) -> String {
        if includeGroups || !tableColumnNames("ZREMCDBASELIST").contains("ZISGROUP") { return "" }
        return "AND COALESCE(ZISGROUP, 0) = 0 "
    }

    /// q_lists, minimal columns for name resolution. ORDER BY ZNAME (binary), Z_ENT=3, named only.
    func listsForResolution() -> [Row] {
        let filter = listGroupFilterSQL(includeGroups: false)  // OUTSIDE the read (reentrancy)
        return (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' \(filter)ORDER BY ZNAME") }) ?? []
    }

    /// q_list_groups, minimal columns for name resolution: the group rows `listsForResolution`
    /// filters out. A store without ZISGROUP has no groups.
    func listGroupsForResolution() -> [Row] {
        guard tableColumnNames("ZREMCDBASELIST").contains("ZISGROUP") else { return [] }
        return (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' AND COALESCE(ZISGROUP, 0) = 1 ORDER BY ZNAME") }) ?? []
    }

    func listByPkForResolution(_ id: Int) -> Row? {
        let groupColumn = tableColumnNames("ZREMCDBASELIST").contains("ZISGROUP") ? ", ZISGROUP" : ""
        return try? queue.read { try Row.fetchOne($0, sql:
            "SELECT Z_PK, ZNAME, ZCKIDENTIFIER\(groupColumn) FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''",
            arguments: [id]) }
    }

    /// Port of `list_resolution_from_rows`: 3-tier name match (exact → casefold → normalized)
    /// over one set of candidate rows. `nil` means no tier matched, so the caller can try the
    /// list groups next.
    func resolution(from rows: [Row], name: String) -> ListResolution? {
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
        // tier 2: case-insensitive (Python str.casefold(), NOT .lowercased())
        let folded = unicodeCasefold(name)
        let ci = rows.filter { unicodeCasefold($0.string("ZNAME") ?? "") == folded }
        if ci.count == 1 { return found(ci[0]) }
        if ci.count > 1 { return candidates(ci) }
        // tier 3: normalized
        let normalized = normalizeListLookupName(name)
        if normalized.isEmpty { return nil }
        let nm = rows.filter { normalizeListLookupName($0.string("ZNAME") ?? "") == normalized }
        if nm.count == 1 { return found(nm[0]) }
        if nm.count > 1 { return candidates(nm) }
        return nil
    }

    /// Promote a resolved row to `.group`, carrying the child lists the group error message (and
    /// `show`) needs, in Reminders' child order.
    private func groupResolution(id: Int, title: String, objectUUID: String?) -> ListResolution {
        .group(id: id, title: title, objectUUID: objectUUID,
               children: childLists(groupPk: id).map { (id: $0.int("Z_PK") ?? 0, title: $0.string("ZNAME") ?? "") })
    }

    /// Port of resolve_list_ref: by id, or 3-tier name match (exact → casefold → normalized),
    /// lists first and list groups second.
    public func resolveListRef(name: String?, listId: Int?) -> ListResolution {
        if let listId {
            guard let row = listByPkForResolution(listId) else { return .notFound }
            let id = row.int("Z_PK") ?? listId
            let title = row.string("ZNAME") ?? ""
            let uuid = row.string("ZCKIDENTIFIER")
            if isGroupListRow(row) { return groupResolution(id: id, title: title, objectUUID: uuid) }
            return .found(id: id, title: title, objectUUID: uuid)
        }
        guard let name, !name.isEmpty else { return .notFound }
        if let listResult = resolution(from: listsForResolution(), name: name) { return listResult }
        // An ambiguous group name stays ambiguous; a single match resolves to the group itself.
        guard let groupResult = resolution(from: listGroupsForResolution(), name: name) else { return .notFound }
        guard case let .found(id, title, uuid) = groupResult else { return groupResult }
        return groupResolution(id: id, title: title, objectUUID: uuid)
    }

    /// Resolve a list AND report which tier matched, mirroring `resolve_list_ref`'s `method`
    /// (`id`/`exact`/`case_insensitive`/`normalized`). Used by template-create to build the full
    /// `list_ref_payload`. `.found` carries the resolution method as the title-adjacent payload.
    public func resolveListRefWithMethod(name: String?, listId: Int?)
        -> (resolution: ListResolution, method: String)
    {
        if listId != nil {
            return (resolveListRef(name: name, listId: listId), "id")
        }
        guard let name, !name.isEmpty else { return (.notFound, "exact") }
        let rows = listsForResolution()
        // tier 1: exact
        if rows.filter({ $0.string("ZNAME") == name }).count == 1 {
            return (resolveListRef(name: name, listId: nil), "exact")
        }
        // tier 2: case-insensitive
        let folded = unicodeCasefold(name)
        if rows.filter({ unicodeCasefold($0.string("ZNAME") ?? "") == folded }).count == 1 {
            return (resolveListRef(name: name, listId: nil), "case_insensitive")
        }
        // tier 3: normalized
        return (resolveListRef(name: name, listId: nil), "normalized")
    }

    /// Re-read a resolved list (by Z_PK) with the FULL `list_select_columns` set so callers can
    /// build a complete `list_ref_payload` (grocery fields require those columns).
    public func listRowByPkFull(_ pk: Int) -> GRDB.Row? {
        let cols = listSelectColumns().joined(separator: ", ")
        let sql = "SELECT \(cols) FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [pk]) }
    }

    /// q_list_reminder_count_for_template (remctl:994): count of live, account-attached reminders in
    /// a list (gating the template-create post-write poll). Adds `ZCOMPLETED = 0` unless
    /// `includeCompleted`. Returns nil when the underlying query errors (mirrors the Python
    /// try/except sqlite3.OperationalError → None).
    public func listReminderCountForTemplate(listPk: Int, includeCompleted: Bool) -> Int? {
        var where_ = ["ZMARKEDFORDELETION = 0", "ZLIST = ?", "ZACCOUNT IS NOT NULL"]
        if !includeCompleted { where_.append("ZCOMPLETED = 0") }
        let sql = "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE \(where_.joined(separator: " AND "))"
        return try? queue.read { try Int.fetchOne($0, sql: sql, arguments: [listPk]) }
    }

    /// Re-read a newly created list by its CloudKit identifier after template-apply
    /// (remctl:4362): `SELECT … FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3
    /// AND ZCKIDENTIFIER = ?` with the full `list_select_columns` set (for `list_to_dict`).
    public func listRowByCkid(_ ckid: String) -> GRDB.Row? {
        let cols = listSelectColumns().joined(separator: ", ")
        let sql = "SELECT \(cols) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZCKIDENTIFIER = ?"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [ckid]) }
    }
}

/// Port of `list_ref_payload` (remctl:1174): ordered keys id, title, objectUUID, requested, method,
/// listType, isGroup, isGroceries, [parentListId], [grocery]. `requested` is the original user
/// input string (name or "id N").
public func listRefPayload(_ row: ReminderRow, requested: String?, method: String) -> [(String, JSONValue)] {
    let isGroup = isGroupListRow(row)
    let isGroceries = isGroceryListRow(row)
    var payload: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("title", row.string("ZNAME").map { .string($0) } ?? .null),
        ("objectUUID", row.string("ZCKIDENTIFIER").map { .string($0) } ?? .null),
        ("requested", requested.map { .string($0) } ?? .null),
        ("method", .string(method)),
        ("listType", .string(isGroup ? "group" : isGroceries ? "groceries" : "standard")),
        ("isGroup", .bool(isGroup)),
        ("isGroceries", .bool(!isGroup && isGroceries)),
    ]
    if let parentId = listParentPk(row) { payload.append(("parentListId", .int(parentId))) }
    if let grocery = groceryListPayload(row), !isGroup,
       isGroceries || groceryHasAnyTruthyRef(grocery) {
        payload.append(("grocery", .object(grocery)))
    }
    return payload
}

/// Local copy of the grocery-truthiness predicate (ListSerializer's is private).
private func groceryHasAnyTruthyRef(_ pairs: [(String, JSONValue)]) -> Bool {
    pairs.contains { _, v in
        switch v {
        case .bool(let b): return b
        case .string(let s): return !s.isEmpty
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        default: return false
        }
    }
}

extension RemindersStore {
    /// Dynamic column set for q_lists (mirrors list_select_columns).
    func listSelectColumns() -> [String] {
        var cols = ["Z_PK", "ZNAME", "ZCKIDENTIFIER"]
        let t = tableColumnNames("ZREMCDBASELIST")
        for c in ["ZBADGEEMBLEM", "ZCOLOR", "ZISGROUP", "ZPARENTLIST", "ZPARENTLIST1",
                  "Z_FOK_PARENTLIST", "Z_FOK_PARENTLIST1", "ZDADISPLAYORDER",
                  "ZISPINNEDBYCURRENTUSER", "ZPINNEDDATE",
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

    /// q_base_lists: named user lists (Z_ENT=3), ORDER BY ZNAME (binary). `includeGroups` keeps
    /// the list groups in, which only the `lists` hierarchy view wants.
    public func lists(includeGroups: Bool) -> [Row] {
        // Built OUTSIDE the read (reentrancy).
        let cols = listSelectColumns().joined(separator: ", ")
        let filter = listGroupFilterSQL(includeGroups: includeGroups)
        let sql = "SELECT \(cols) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' \(filter)ORDER BY ZNAME"
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }

    /// Port of `q_child_lists`: the lists a group contains, in Reminders' child order. Reminders
    /// has used both ZPARENTLIST and ZPARENTLIST1 for the group reference, so both are matched
    /// when present.
    public func childLists(groupPk: Int) -> [Row] {
        let t = tableColumnNames("ZREMCDBASELIST")
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for column in ["ZPARENTLIST", "ZPARENTLIST1"] where t.contains(column) {
            clauses.append("\(column) = ?")
            args.append(groupPk)
        }
        guard !clauses.isEmpty else { return [] }
        let cols = listSelectColumns().joined(separator: ", ")
        let filter = listGroupFilterSQL(includeGroups: false)
        let sql = "SELECT \(cols) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' \(filter)AND (\(clauses.joined(separator: " OR ")))"
        let rows = (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
        return rows.sorted(by: listChildPrecedes)
    }

    /// Port of `q_list_reminder_counts`: active/completed/total top-level reminders per list,
    /// for the counts `lists --json` reports on a group and its children. Schema-guarded: a store
    /// without the reminder table (or its list column) reports no counts.
    public func listReminderCounts(listPks: [Int]) -> [Int: ListReminderCounts] {
        guard !listPks.isEmpty else { return [:] }
        let columns = tableColumnNames("ZREMCDREMINDER")
        guard columns.contains("ZLIST") else { return [:] }
        let placeholders = Array(repeating: "?", count: listPks.count).joined(separator: ", ")
        var where_ = ["ZLIST IN (\(placeholders))"]
        if columns.contains("ZMARKEDFORDELETION") { where_.append("ZMARKEDFORDELETION = 0") }
        if columns.contains("ZACCOUNT") { where_.append("ZACCOUNT IS NOT NULL") }
        if columns.contains("ZPARENTREMINDER") { where_.append("(ZPARENTREMINDER IS NULL OR ZPARENTREMINDER = 0)") }
        let completed = columns.contains("ZCOMPLETED") ? "ZCOMPLETED" : "0"
        let sql = "SELECT ZLIST AS list_id, "
            + "SUM(CASE WHEN \(completed) = 0 THEN 1 ELSE 0 END) AS active_count, "
            + "SUM(CASE WHEN \(completed) = 1 THEN 1 ELSE 0 END) AS completed_count, "
            + "COUNT(*) AS total_count FROM ZREMCDREMINDER "
            + "WHERE \(where_.joined(separator: " AND ")) GROUP BY ZLIST"
        let rows = (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(listPks)) }) ?? []
        var counts: [Int: ListReminderCounts] = [:]
        for row in rows {
            guard let listId = row.int("list_id") else { continue }
            let active = row.int("active_count") ?? 0
            let done = row.int("completed_count") ?? 0
            counts[listId] = ListReminderCounts(active: active, completed: done,
                                                total: row.int("total_count") ?? (active + done))
        }
        return counts
    }

    /// Count of live sections for a list (q_sections list_pk count, for the human lists view).
    public func sectionCountForList(_ pk: Int) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ?", arguments: [pk]) ?? 0 }) ?? 0
    }
}

/// True Unicode case-fold, equivalent to Python `str.casefold()` (NOT `str.lowercased()`).
/// Uses ICU's full case-folding via `CFStringFold(.compareCaseInsensitive)`, which matches Python
/// on the divergent cases (`ß`→`ss`, final sigma `ς`→`σ`, ligatures, `İ`→`i`+U+0307, etc.).
public func unicodeCasefold(_ s: String) -> String {
    let m = NSMutableString(string: s)
    CFStringFold(m as CFMutableString, .compareCaseInsensitive, nil)
    return m as String
}

/// Port of normalize_list_lookup_name (remctl:771): NFKC-normalize, then casefold, then iterate
/// over Unicode SCALARS (not grapheme clusters — Python iterates codepoints): alphanumeric scalars
/// (`str.isalnum()` == alphabetic OR numeric) are kept; scalars in general-category M/P/S/Z or
/// whitespace collapse runs to a single space; everything else is dropped; finally strip.
public func normalizeListLookupName(_ name: String) -> String {
    if name.isEmpty { return "" }
    let text = unicodeCasefold((name as NSString).precomposedStringWithCompatibilityMapping)
    var parts: [Character] = []
    var lastSpace = false
    for sc in text.unicodeScalars {
        let p = sc.properties
        // Python str.isalnum(): isalpha() OR isdecimal()/isdigit()/isnumeric().
        if p.isAlphabetic || p.numericType != nil {
            parts.append(Character(sc)); lastSpace = false
        } else if p.isWhitespace || isMarkPunctSymbolSep(p.generalCategory) {
            if !parts.isEmpty && !lastSpace { parts.append(" "); lastSpace = true }
        }
    }
    return String(parts).trimmingCharacters(in: .whitespaces)
}

/// Unicode general categories M*, P*, S*, Z* (the runs Python collapses to a single space).
private func isMarkPunctSymbolSep(_ gc: Unicode.GeneralCategory) -> Bool {
    switch gc {
    case .nonspacingMark, .spacingMark, .enclosingMark,                                  // M*
         .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation,                      // P*
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,                    // S*
         .spaceSeparator, .lineSeparator, .paragraphSeparator:                           // Z*
        return true
    default:
        return false
    }
}

extension RemindersStore {
    /// q_sections(list_pk): a list's sections, ordered by Z_PK.
    public func sectionsForList(_ pk: Int) -> [Row] {
        (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ? ORDER BY Z_PK", arguments: [pk]) }) ?? []
    }

    /// q_section_memberships: reminder ZCKIDENTIFIER -> section ZDISPLAYNAME, from each member's
    /// effective membership (display keeps the last live entry when dates cannot decide).
    public func sectionMemberships(_ pk: Int) -> [String: String] {
        let memberships = effectiveSectionMemberships(sectionMembershipEntries(pk: pk), strict: false)
        guard !memberships.isEmpty else { return [:] }
        // section ckid -> display name (separate read, sequential — not nested)
        let secRows = (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT ZCKIDENTIFIER, ZDISPLAYNAME FROM ZREMCDBASESECTION WHERE ZLIST = ? AND ZMARKEDFORDELETION = 0", arguments: [pk]) }) ?? []
        var g2n: [String: String] = [:]
        for r in secRows { if let ck = r.string("ZCKIDENTIFIER") { g2n[ck] = r.string("ZDISPLAYNAME") } }
        return memberships.compactMapValues { g2n[$0] }
    }

    /// Whether a list (by Z_PK) is a grocery list.
    public func listIsGroceries(_ pk: Int) -> Bool {
        ((try? queue.read { try Int.fetchOne($0, sql:
            "SELECT ZSHOULDCATEGORIZEGROCERYITEMS FROM ZREMCDBASELIST WHERE Z_PK = ?", arguments: [pk]) }) ?? nil ?? 0) != 0
    }

    /// Port of `q_list_by_pk` (remctl:984) restricted to the columns `require_grocery_list_target`
    /// (remctl:2898) needs: the list's display name and its grocery flag. Mirrors the source WHERE
    /// clause (Z_ENT=3, not deleted, named) — a non-list pk (or a deleted/unnamed list) returns nil,
    /// which the caller maps to "Error: target list not found." Returns `(name, isGroceries)`.
    public func groceryListTarget(pk: Int) -> (name: String, isGroceries: Bool)? {
        guard let row = try? queue.read({ try Row.fetchOne($0, sql:
            "SELECT ZNAME, ZSHOULDCATEGORIZEGROCERYITEMS FROM ZREMCDBASELIST "
            + "WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''",
            arguments: [pk]) }) ?? nil else { return nil }
        let name = row.string("ZNAME") ?? ""
        let isGroceries = (row.int("ZSHOULDCATEGORIZEGROCERYITEMS") ?? 0) != 0
        return (name: name, isGroceries: isGroceries)
    }
}

/// Port of `_print_list_resolution_error`'s `list_is_group` branch: a group holds lists, so the
/// message points at the child lists a reminder can actually go in.
public func listIsGroupMessage(title: String, children: [(id: Int, title: String)]) -> String {
    var message = "\(WriteFormatting.pyRepr(title)) is a Reminders list group, not a writable list."
    if !children.isEmpty {
        let options = children.map { "\($0.title) (id \($0.id))" }.joined(separator: ", ")
        message += " Use one of its child lists: \(options)"
    }
    return message
}

/// Command-level helper mirroring resolve_required_list_target_or_die — throws CLIError
/// (Dispatch.runRead prints "Error: <msg>" + exit 1). Returns the resolved list. `allowGroups`
/// (upstream's flag of the same name) is only for `show`, which can read a whole group.
public func resolveRequiredListTarget(store: RemindersStore, name: String?, listId: Int?,
                                      allowGroups: Bool = false) throws
    -> (id: Int, title: String, objectUUID: String?, isGroup: Bool)
{
    if name == nil && listId == nil {
        throw CLIError("pass a list name or --list-id.", code: "invalid_list_target")
    }
    if name != nil && listId != nil {
        throw CLIError("pass either a list name or --list-id, not both.", code: "invalid_list_target")
    }
    let requested = listId != nil ? "id \(listId!)" : (name ?? "")
    switch store.resolveListRef(name: name, listId: listId) {
    case .found(let id, let title, let uuid):
        return (id, title, uuid, false)
    case .group(let id, let title, let uuid, let children):
        guard allowGroups else {
            throw CLIError(listIsGroupMessage(title: title, children: children), code: "list_is_group")
        }
        return (id, title, uuid, true)
    case .ambiguous(let candidates):
        let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
        throw CLIError("multiple lists match '\(requested)'. Use the exact list name or --list-id with one of: \(options)",
                       code: "list_ambiguous")
    case .notFound:
        throw CLIError("list not found: \(requested)", code: "list_not_found")
    }
}
