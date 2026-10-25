import GRDB
import Foundation

extension RemindersStore {
    /// preload_indicators — trailing-badge flags for a page of reminders, keyed by reminder
    /// Z_PK. Reminders with neither flag are absent from the map. One query per backing
    /// table, soft-deleted rows excluded.
    ///
    /// Independent of `preloadAttachments`: a reminder can carry a rich link without any
    /// attachment row.
    public func preloadIndicators(_ pks: [Int]) -> [Int: ReminderBadges] {
        guard !pks.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: pks.count).joined(separator: ",")
        let args = StatementArguments(pks)
        var badges: [Int: ReminderBadges] = [:]

        func fetch(_ sql: String) -> [Row] {
            (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: args) }) ?? []
        }
        func mark(_ row: Row, link: Bool = false, image: Bool = false) {
            guard let rid = row.int("rid") else { return }
            var flags = badges[rid] ?? ReminderBadges()
            flags.link = flags.link || link
            flags.image = flags.image || image
            badges[rid] = flags
        }

        if !tableColumnNames("ZREMCDSAVEDATTACHMENT").isEmpty {
            let rows = fetch(
                "SELECT ZREMINDER AS rid, ZATTACHMENTTYPERAWVALUE AS type FROM ZREMCDSAVEDATTACHMENT "
                + "WHERE ZREMINDER IN (\(placeholders)) AND +ZMARKEDFORDELETION = 0")
            for row in rows {
                switch row.string("type")?.trimmingCharacters(in: .whitespaces).lowercased() {
                case "url": mark(row, link: true)
                case "image": mark(row, image: true)
                default: continue
                }
            }
        }

        let object = tableColumnNames("ZREMCDOBJECT")
        if !object.isEmpty {
            func column(_ name: String) -> String { object.contains(name) ? name : "NULL" }
            let rows = fetch(
                "SELECT ZREMINDER2 AS rid, ZURL AS url, ZFILENAME AS filename, "
                + "\(column("ZWIDTH")) AS width, \(column("ZHEIGHT")) AS height FROM ZREMCDOBJECT "
                + "WHERE ZREMINDER2 IN (\(placeholders)) AND +ZMARKEDFORDELETION = 0 "
                + "AND ((ZURL IS NOT NULL AND ZURL != '') OR (ZFILENAME IS NOT NULL AND ZFILENAME != ''))")
            for row in rows {
                let hasFile = row.string("filename")?.isEmpty == false
                let hasDimensions = row.double("width") != nil || row.double("height") != nil
                mark(row, link: row.string("url")?.isEmpty == false, image: hasFile && hasDimensions)
            }
        }
        return badges.filter { !$0.value.isEmpty }
    }
}
