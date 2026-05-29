import GRDB
import Foundation

extension RemindersStore {
    /// Batch subtask counts (active children) + hashtags, keyed by reminder Z_PK. Mirrors preload_extras.
    public func preloadExtras(_ pks: [Int]) -> (subtaskCounts: [Int: Int], hashtags: [Int: [String]]) {
        guard !pks.isEmpty else { return ([:], [:]) }
        let placeholders = Array(repeating: "?", count: pks.count).joined(separator: ",")
        let args = StatementArguments(pks)
        var counts: [Int: Int] = [:]
        var tags: [Int: [String]] = [:]
        try? queue.read { db in
            let subRows = try Row.fetchAll(db, sql:
                "SELECT ZPARENTREMINDER, COUNT(*) AS c FROM ZREMCDREMINDER WHERE ZPARENTREMINDER IN (\(placeholders)) AND ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 GROUP BY ZPARENTREMINDER",
                arguments: args)
            for r in subRows { if let p: Int = r["ZPARENTREMINDER"] { counts[p] = r["c"] } }
            let tagRows = try Row.fetchAll(db, sql:
                "SELECT o.ZREMINDER3 AS rid, h.ZNAME AS name FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 IN (\(placeholders))",
                arguments: args)
            for r in tagRows { if let rid: Int = r["rid"], let name: String = r["name"] { tags[rid, default: []].append(name) } }
        }
        return (counts, tags)
    }

    /// First rich-link URL for a reminder (q_rich_link). Used as the url fallback.
    public func richLink(pk: Int) -> String? {
        try? queue.read { db in
            try String.fetchOne(db, sql:
                "SELECT ZURL FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZURL IS NOT NULL AND ZURL != '' AND ZMARKEDFORDELETION = 0 ORDER BY Z_PK",
                arguments: [pk])
        }
    }
}
