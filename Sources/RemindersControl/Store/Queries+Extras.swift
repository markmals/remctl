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
                "SELECT ZPARENTREMINDER, COUNT(*) AS c FROM ZREMCDREMINDER WHERE ZPARENTREMINDER IN (\(placeholders)) AND +ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 GROUP BY ZPARENTREMINDER",
                arguments: args)
            for r in subRows { if let p: Int = r["ZPARENTREMINDER"] { counts[p] = r["c"] } }
            let tagRows = try Row.fetchAll(db, sql:
                "SELECT o.ZREMINDER3 AS rid, h.ZNAME AS name FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 IN (\(placeholders)) AND +o.ZMARKEDFORDELETION = 0",
                arguments: args)
            for r in tagRows { if let rid: Int = r["rid"], let name: String = r["name"] { tags[rid, default: []].append(name) } }
        }
        return (counts, tags)
    }

    /// First rich-link URL for a reminder (q_rich_link). Used as the url fallback.
    public func richLink(pk: Int) -> String? {
        try? queue.read { db in
            try String.fetchOne(db, sql:
                "SELECT ZURL FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZURL IS NOT NULL AND ZURL != '' AND +ZMARKEDFORDELETION = 0 ORDER BY Z_PK",
                arguments: [pk])
        }
    }
}

extension RemindersStore {
    /// q_hashtags — tag names for one reminder via ZREMCDOBJECT.ZREMINDER3 join ZREMCDHASHTAGLABEL.
    public func hashtags(pk: Int) -> [String] {
        (try? queue.read { try String.fetchAll($0, sql:
            "SELECT h.ZNAME FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 = ? AND +o.ZMARKEDFORDELETION = 0",
            arguments: [pk]) }) ?? []
    }

    /// q_alarms — alarm objects (REMCDAlarm) LEFT JOIN their trigger object, ORDER BY a.Z_PK,
    /// without the time-interval half of a location alarm (`alarmsWithoutLocationCompanions`).
    public func alarms(pk: Int) -> [Row] {
        let ent = alarmEntity
        let alarmUID = tableColumnNames("ZREMCDOBJECT").contains("ZALARMUID") ? "a.ZALARMUID" : "NULL"
        let sql = "SELECT a.Z_PK AS alarm_id, \(alarmUID) AS alarm_uid, a.ZTRIGGER AS trigger_id, t.Z_ENT AS trigger_entity, t.ZTIMEINTERVAL AS time_interval, " +
            "t.ZDATECOMPONENTSDATA AS date_components, t.ZTITLE AS location_title, t.ZLATITUDE AS latitude, t.ZLONGITUDE AS longitude, " +
            "t.ZRADIUS AS radius, t.ZADDRESS AS address, t.ZPROXIMITY AS proximity " +
            "FROM ZREMCDOBJECT a LEFT JOIN ZREMCDOBJECT t ON a.ZTRIGGER = t.Z_PK " +
            "WHERE a.ZREMINDER = ? AND +a.Z_ENT = \(ent) AND +a.ZMARKEDFORDELETION = 0 AND (t.Z_PK IS NULL OR t.ZMARKEDFORDELETION = 0) " +
            "ORDER BY a.Z_PK"
        let rows = (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk]) }) ?? []
        return alarmsWithoutLocationCompanions(rows)
    }
}

/// Reminders saves an EventKit location alarm as two REMCDAlarm rows sharing one ZALARMUID: the
/// location trigger, and a time-interval trigger at offset 0. EventKit reads the pair back as a
/// single location alarm, so the time-interval row is dropped; a genuine at-due-time alarm has a
/// ZALARMUID of its own and stays.
func alarmsWithoutLocationCompanions<Alarm: ReminderRow>(_ rows: [Alarm]) -> [Alarm] {
    let locationAlarmUIDs = Set(rows.compactMap { row -> String? in
        guard row.double("latitude") != nil || row.double("longitude") != nil else { return nil }
        return row.string("alarm_uid")
    })
    return rows.filter { row in
        guard row.double("time_interval") == 0, let uid = row.string("alarm_uid") else { return true }
        return !locationAlarmUIDs.contains(uid)
    }
}
