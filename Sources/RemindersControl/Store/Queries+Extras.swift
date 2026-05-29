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

extension RemindersStore {
    /// q_hashtags — tag names for one reminder via ZREMCDOBJECT.ZREMINDER3 join ZREMCDHASHTAGLABEL.
    public func hashtags(pk: Int) -> [String] {
        (try? queue.read { try String.fetchAll($0, sql:
            "SELECT h.ZNAME FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 = ?",
            arguments: [pk]) }) ?? []
    }

    /// q_attachments — UNION ALL of saved attachments + ZREMCDOBJECT image/file rows, ORDER BY ZFILENAME.
    public func attachments(pk: Int) -> [Row] {
        let sql = "SELECT ZFILENAME, ZUTI, ZATTACHMENTTYPERAWVALUE FROM ZREMCDSAVEDATTACHMENT WHERE ZREMINDER = ? AND ZMARKEDFORDELETION = 0 " +
            "UNION ALL " +
            "SELECT ZFILENAME, ZUTI, CASE WHEN ZWIDTH IS NOT NULL OR ZHEIGHT IS NOT NULL THEN 'image' ELSE 'file' END AS ZATTACHMENTTYPERAWVALUE " +
            "FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZFILENAME IS NOT NULL AND ZFILENAME != '' AND ZMARKEDFORDELETION = 0 " +
            "ORDER BY ZFILENAME"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk, pk]) }) ?? []
    }

    /// q_alarms — alarm objects (Z_ENT=15) LEFT JOIN their trigger object, ORDER BY a.Z_PK.
    public func alarms(pk: Int) -> [Row] {
        let sql = "SELECT a.Z_PK AS alarm_id, a.ZTRIGGER AS trigger_id, t.Z_ENT AS trigger_entity, t.ZTIMEINTERVAL AS time_interval, " +
            "t.ZDATECOMPONENTSDATA AS date_components, t.ZTITLE AS location_title, t.ZLATITUDE AS latitude, t.ZLONGITUDE AS longitude, " +
            "t.ZRADIUS AS radius, t.ZADDRESS AS address, t.ZPROXIMITY AS proximity " +
            "FROM ZREMCDOBJECT a LEFT JOIN ZREMCDOBJECT t ON a.ZTRIGGER = t.Z_PK " +
            "WHERE a.ZREMINDER = ? AND a.Z_ENT = \(Zent.alarm) AND a.ZMARKEDFORDELETION = 0 AND (t.Z_PK IS NULL OR t.ZMARKEDFORDELETION = 0) " +
            "ORDER BY a.Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk]) }) ?? []
    }
}
