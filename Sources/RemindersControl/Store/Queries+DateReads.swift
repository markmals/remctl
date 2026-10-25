import GRDB
import Foundation

extension RemindersStore {
    /// Whether the reminder has a live absolute alarm (an alarm whose trigger carries date
    /// components). Resolves the ambiguous half of `timedDueRaw`, so it only runs for a row
    /// whose display date coincides with its wall-clock reading.
    public func hasAbsoluteAlarm(pk: Int) -> Bool {
        let ent = alarmEntity
        let sql = "SELECT 1 FROM ZREMCDOBJECT a JOIN ZREMCDOBJECT t ON a.ZTRIGGER = t.Z_PK " +
            "WHERE a.ZREMINDER = ? AND +a.Z_ENT = \(ent) AND +a.ZMARKEDFORDELETION = 0 " +
            "AND t.ZMARKEDFORDELETION = 0 AND t.ZDATECOMPONENTSDATA IS NOT NULL LIMIT 1"
        return ((try? queue.read { try Int.fetchOne($0, sql: sql, arguments: [pk]) }) ?? nil) != nil
    }

    /// Port of `q_due_date_delta_alerts` (upstream 088fab4). Early Reminder rows for a
    /// reminder, from the macOS 27 `ZREMCDDUEDATEDELTAALERT` table. Empty when the store
    /// predates that table or the ckid is not a UUID.
    public func dueDateDeltaAlertRows(reminderCkid: String) -> [Row] {
        guard let identifier = UUID(uuidString: reminderCkid) else { return [] }
        let blob = withUnsafeBytes(of: identifier.uuid) { Data($0) }
        let sql = "SELECT ZIDENTIFIER, ZDUEDATEDELTAUNIT, ZDUEDATEDELTACOUNT, " +
            "ZMINIMUMSUPPORTEDAPPVERSION, ZCREATIONDATE, ZACKNOWLEDGEDDATE " +
            "FROM ZREMCDDUEDATEDELTAALERT WHERE ZREMINDERIDENTIFIER = ? " +
            "ORDER BY COALESCE(ZSORTORDER, 0), Z_PK"
        return (try? queue.read { db in
            try db.tableExists("ZREMCDDUEDATEDELTAALERT")
                ? Row.fetchAll(db, sql: sql, arguments: [blob]) : []
        }) ?? []
    }

    /// Early Reminders for a reminder read from the fallback table, in JSON shape.
    public func earlyReminderAlerts(_ reminderCkid: String) -> [[(String, JSONValue)]] {
        dueDateDeltaAlertRowsToJSON(dueDateDeltaAlertRows(reminderCkid: reminderCkid))
    }
}

/// Port of `due_date_delta_alert_rows_to_json` (upstream 088fab4). Same shape as the
/// envelope-blob reader `dueDateDeltaAlertsFromRow`, plus `acknowledgedDate`.
public func dueDateDeltaAlertRowsToJSON(_ rows: [Row]) -> [[(String, JSONValue)]] {
    rows.compactMap { row in
        guard let unitRaw = row.int("ZDUEDATEDELTAUNIT"), let count = row.int("ZDUEDATEDELTACOUNT") else {
            return nil
        }
        let (singular, plural) = Constants.dueDateDeltaUnits[unitRaw] ?? ("unknown", "unknown")
        let value = abs(count)
        let unitName = value == 1 ? singular : plural
        let direction = count < 0 ? "before" : "after"
        var item: [(String, JSONValue)] = [
            ("unit", .string(unitName)), ("unitCode", .int(unitRaw)), ("count", .int(count)),
            ("value", .int(value)), ("direction", .string(direction)),
            ("label", .string("\(value) \(unitName) \(direction)")),
        ]
        if let id = uuidFromBlob(row.data("ZIDENTIFIER")) { item.append(("identifier", .string(id))) }
        if let created = row.double("ZCREATIONDATE"), let iso = AppleEpoch.ts(created) {
            item.append(("creationDate", .string(iso)))
        }
        if let acked = row.double("ZACKNOWLEDGEDDATE"), let iso = AppleEpoch.ts(acked) {
            item.append(("acknowledgedDate", .string(iso)))
        }
        if let minimum = row.int("ZMINIMUMSUPPORTEDAPPVERSION") {
            item.append(("minimumSupportedAppVersion", .int(minimum)))
        }
        return item
    }
}
