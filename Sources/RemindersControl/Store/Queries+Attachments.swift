import GRDB
import Foundation

/// One attachment row, from either backing table: `ZREMCDSAVEDATTACHMENT` (saved
/// attachments, typed `image`/`file`/`url`) or `ZREMCDOBJECT` (synced file objects,
/// typed from their pixel dimensions).
public struct AttachmentRow: Equatable {
    public let filename: String?
    public let type: String?
    public let uti: String?
    public let sha512: String?
    public let width: Double?
    public let height: Double?

    public init(filename: String?, type: String?, uti: String?, sha512: String?,
                width: Double? = nil, height: Double? = nil) {
        self.filename = filename
        self.type = type
        self.uti = uti
        self.sha512 = sha512
        self.width = width
        self.height = height
    }
}

extension RemindersStore {
    /// preload_attachments — attachment rows for a page of reminders, grouped by reminder
    /// Z_PK and sorted by filename. One query per backing table, soft-deleted rows excluded.
    ///
    /// `ZSHA512SUM`, `ZUTI` and `ZWIDTH`/`ZHEIGHT` only exist on newer Reminders schemas, so
    /// each is selected as NULL when this store's table lacks it; a table that is missing
    /// entirely contributes no rows.
    public func preloadAttachments(_ pks: [Int]) -> [Int: [AttachmentRow]] {
        guard !pks.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: pks.count).joined(separator: ",")
        let args = StatementArguments(pks)
        var grouped: [Int: [AttachmentRow]] = [:]

        func fetch(_ sql: String) -> [Row] {
            (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: args) }) ?? []
        }
        func append(_ row: Row, _ attachment: AttachmentRow) {
            guard let rid = row.int("rid") else { return }
            grouped[rid, default: []].append(attachment)
        }

        let saved = tableColumnNames("ZREMCDSAVEDATTACHMENT")
        if !saved.isEmpty {
            let sha = saved.contains("ZSHA512SUM") ? "ZSHA512SUM" : "NULL"
            let rows = fetch(
                "SELECT ZREMINDER AS rid, ZFILENAME AS filename, ZUTI AS uti, "
                + "ZATTACHMENTTYPERAWVALUE AS type, \(sha) AS sha FROM ZREMCDSAVEDATTACHMENT "
                + "WHERE ZREMINDER IN (\(placeholders)) AND +ZMARKEDFORDELETION = 0")
            for row in rows {
                append(row, AttachmentRow(filename: row.string("filename"), type: row.string("type"),
                                          uti: row.string("uti"), sha512: row.string("sha")))
            }
        }

        let object = tableColumnNames("ZREMCDOBJECT")
        if !object.isEmpty {
            func column(_ name: String) -> String { object.contains(name) ? name : "NULL" }
            let width = column("ZWIDTH"), height = column("ZHEIGHT")
            let rows = fetch(
                "SELECT ZREMINDER2 AS rid, ZFILENAME AS filename, \(column("ZUTI")) AS uti, "
                + "CASE WHEN \(width) IS NOT NULL OR \(height) IS NOT NULL THEN 'image' ELSE 'file' END AS type, "
                + "\(column("ZSHA512SUM")) AS sha, \(width) AS width, \(height) AS height FROM ZREMCDOBJECT "
                + "WHERE ZREMINDER2 IN (\(placeholders)) AND ZFILENAME IS NOT NULL AND ZFILENAME != '' "
                + "AND +ZMARKEDFORDELETION = 0")
            for row in rows {
                append(row, AttachmentRow(filename: row.string("filename"), type: row.string("type"),
                                          uti: row.string("uti"), sha512: row.string("sha"),
                                          width: row.double("width"), height: row.double("height")))
            }
        }

        // Stable by filename: saved attachments keep their lead over object rows on a tie.
        return grouped.mapValues { rows in
            rows.enumerated().sorted { a, b in
                let left = a.element.filename ?? "", right = b.element.filename ?? ""
                return left == right ? a.offset < b.offset : left < right
            }.map(\.element)
        }
    }

    /// q_attachments — attachment rows for one reminder, through the batch preload.
    public func attachments(pk: Int) -> [AttachmentRow] { preloadAttachments([pk])[pk] ?? [] }

    /// The verified on-disk path for one of this store's attachment rows, or nil.
    public func resolveAttachmentPath(_ row: AttachmentRow) -> String? {
        attachmentResolver.resolve(sha512: row.sha512, filename: row.filename, uti: row.uti)
    }
}
