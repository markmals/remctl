import GRDB
import Foundation

public enum TemplateResolution {
    case found(id: Int, name: String, objectUUID: String?)
    case ambiguous(candidates: [(id: Int, name: String)])
    case notFound
}

extension RemindersStore {
    private func templateSelectColumns() -> [String] {
        var cols = ["Z_PK", "ZNAME", "ZCKIDENTIFIER", "ZCREATIONDATE", "ZLASTMODIFIEDDATE",
                    "ZPUBLICLINKCREATIONDATE", "ZPUBLICLINKEXPIRATIONDATE", "ZPUBLICLINKLASTMODIFIEDDATE"]
        let t = tableColumnNames("ZREMCDTEMPLATE")
        for c in ["ZBADGEEMBLEM", "ZCOLOR", "ZPUBLICLINKURLUUID", "ZPUBLICLINKCONFIGURATIONDATA"] where t.contains(c) {
            cols.append(c)
        }
        return cols
    }

    private var templateCountSubqueries: String {
        "(SELECT COUNT(*) FROM ZREMCDSAVEDREMINDER sr WHERE sr.ZTEMPLATE = ZREMCDTEMPLATE.Z_PK AND sr.ZMARKEDFORDELETION = 0) AS item_count, " +
        "(SELECT COUNT(*) FROM ZREMCDBASESECTION s WHERE s.ZTEMPLATE = ZREMCDTEMPLATE.Z_PK AND s.ZMARKEDFORDELETION = 0) AS section_count"
    }

    /// q_templates.
    public func templates() -> [Row] {
        let cols = templateSelectColumns().joined(separator: ", ")
        let sql = "SELECT \(cols), \(templateCountSubqueries) FROM ZREMCDTEMPLATE WHERE ZMARKEDFORDELETION = 0 AND ZNAME IS NOT NULL AND ZNAME != '' ORDER BY ZNAME, Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }

    /// q_template_matches by id or name.
    public func templateMatches(name: String? = nil, templateId: Int? = nil) -> [Row] {
        let cols = templateSelectColumns().joined(separator: ", ")
        let base = "SELECT \(cols), \(templateCountSubqueries) FROM ZREMCDTEMPLATE "
        if let templateId {
            return (try? queue.read { try Row.fetchAll($0, sql: base + "WHERE ZMARKEDFORDELETION = 0 AND Z_PK = ?", arguments: [templateId]) }) ?? []
        }
        return (try? queue.read { try Row.fetchAll($0, sql: base + "WHERE ZMARKEDFORDELETION = 0 AND ZNAME = ? ORDER BY Z_PK", arguments: [name]) }) ?? []
    }

    public func templateSections(_ pk: Int) -> [Row] {
        let present = tableColumnNames("ZREMCDBASESECTION")
        let cols = ["Z_PK", "ZDISPLAYNAME", "ZCKIDENTIFIER", "ZCANONICALNAME", "ZCREATIONDATE"].filter { present.contains($0) }
        guard !cols.isEmpty else { return [] }
        let sql = "SELECT \(cols.joined(separator: ", ")) FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZTEMPLATE = ? ORDER BY Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk]) }) ?? []
    }

    public func templateSavedReminders(_ pk: Int) -> [Row] {
        let present = tableColumnNames("ZREMCDSAVEDREMINDER")
        let cols = ["Z_PK", "ZTITLE", "ZCKIDENTIFIER", "ZPARENTSAVEDREMINDERIDENTIFIER", "ZPRIORITY",
                    "ZDISPLAYDATEISALLDAY", "ZDISPLAYDATEDATE", "ZCREATIONDATE", "ZMETADATA"].filter { present.contains($0) }
        guard !cols.isEmpty else { return [] }
        let sql = "SELECT \(cols.joined(separator: ", ")) FROM ZREMCDSAVEDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZTEMPLATE = ? ORDER BY Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk]) }) ?? []
    }

    /// resolve_template_ref: by id, or exact-name match (ambiguous if >1).
    public func resolveTemplateRef(name: String?, templateId: Int?) -> TemplateResolution {
        if let templateId {
            let rows = templateMatches(templateId: templateId)
            guard let r = rows.first else { return .notFound }
            return .found(id: r.int("Z_PK") ?? templateId, name: r.string("ZNAME") ?? "", objectUUID: r.string("ZCKIDENTIFIER"))
        }
        guard let name, !name.isEmpty else { return .notFound }
        let rows = templateMatches(name: name)
        if rows.count == 1 {
            return .found(id: rows[0].int("Z_PK") ?? 0, name: rows[0].string("ZNAME") ?? "", objectUUID: rows[0].string("ZCKIDENTIFIER"))
        }
        if rows.count > 1 {
            return .ambiguous(candidates: rows.map { (id: $0.int("Z_PK") ?? 0, name: $0.string("ZNAME") ?? "") })
        }
        return .notFound
    }
}

/// Mirrors resolve_required_template_target_or_die — throws CLIError (Dispatch prints "Error: <msg>" + exit 1).
public func resolveRequiredTemplateTarget(store: RemindersStore, name: String?, templateId: Int?) throws -> Int {
    if name == nil && templateId == nil { throw CLIError("pass a template name or --template-id.") }
    if name != nil && templateId != nil { throw CLIError("pass either a template name or --template-id, not both.") }
    let requested = templateId != nil ? "id \(templateId!)" : (name ?? "")
    switch store.resolveTemplateRef(name: name, templateId: templateId) {
    case .found(let id, _, _): return id
    case .ambiguous(let candidates):
        let options = candidates.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        throw CLIError("multiple templates match '\(requested)'. Use --template-id with one of: \(options)")
    case .notFound:
        throw CLIError("template not found: \(requested)")
    }
}
