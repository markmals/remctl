import Foundation

/// Fallback `Z_ENT` values for stores without a `Z_PRIMARYKEY` row for the entity. Live
/// queries for alarms, assignments, recurrence rules, and sharees resolve the real number
/// via `RemindersStore.entityID(_:fallback:)`, since it differs between macOS versions.
public enum Zent {
    public static let list = 3, smartList = 4, alarm = 15, assignment = 21, recurrence = 34, sharee = 36
}

extension RemindersStore {
    func urgentColumnExpr(_ alias: String = "r") -> String {
        reminderHasColumn("ZISURGENTSTATEENABLEDFORCURRENTUSER")
            ? "\(alias).ZISURGENTSTATEENABLEDFORCURRENTUSER" : "0"
    }
    func urgentWhereClause(_ alias: String = "r") -> String {
        reminderHasColumn("ZISURGENTSTATEENABLEDFORCURRENTUSER")
            ? "\(alias).ZISURGENTSTATEENABLEDFORCURRENTUSER = 1" : "0 = 1"
    }
    func dueDateDeltaAlertsExpr(_ alias: String = "r") -> String {
        reminderHasColumn("ZDUEDATEDELTAALERTSDATA") ? "\(alias).ZDUEDATEDELTAALERTSDATA" : "NULL"
    }
    func displayDueExpr(_ alias: String = "r") -> String {
        reminderHasColumn("ZDISPLAYDATEDATE") ? "\(alias).ZDISPLAYDATEDATE" : "NULL"
    }
    /// Select `ZTIMEZONE` only when the store has it: a NULL would mark every timed
    /// reminder as floating (`timedDueRaw`).
    func timeZoneColumn(_ alias: String = "r") -> String {
        reminderHasColumn("ZTIMEZONE") ? ", \(alias).ZTIMEZONE" : ""
    }
    /// Port of `due_filter_expr`. Date used for due-window bucketing: the one Reminders.app
    /// shows. Reminders.app lists and labels a reminder at ZDISPLAYDATEDATE. For an all-day
    /// item that is the local day, while ZDUEDATE is a synthetic midnight-UTC timestamp. For
    /// a timed item it follows an absolute alarm at another time than the due date, such as
    /// one an EventKit due edit left at the old time, so Today keeps showing the reminder
    /// there. Falls back to plain ZDUEDATE when the display column is absent.
    func dueFilterExpr(_ alias: String = "r") -> String {
        let due = "\(alias).ZDUEDATE"
        guard reminderHasColumn("ZDISPLAYDATEDATE") else { return due }
        return "COALESCE(\(alias).ZDISPLAYDATEDATE, \(due))"
    }

    /// 10 correlated subqueries on ZREMCDOBJECT (REMCDRecurrenceRule, FK ZREMINDER4). Aliases are read by the serializer.
    var recurrenceCols: String {
        let ent = recurrenceRuleEntity
        let pairs: [(String, String)] = [
            ("ZFREQUENCY", "recurrence_frequency"), ("ZINTERVAL", "recurrence_interval"),
            ("ZOCCURRENCECOUNT", "recurrence_count"), ("ZENDDATE", "recurrence_end_date"),
            ("ZDAYSOFTHEWEEK", "recurrence_days_of_week"), ("ZDAYSOFTHEMONTH", "recurrence_days_of_month"),
            ("ZMONTHSOFTHEYEAR", "recurrence_months_of_year"), ("ZDAYSOFTHEYEAR", "recurrence_days_of_year"),
            ("ZWEEKSOFTHEYEAR", "recurrence_weeks_of_year"), ("ZSETPOSITIONS", "recurrence_set_positions"),
        ]
        return pairs.map { col, alias in
            "(SELECT rr.\(col) FROM ZREMCDOBJECT rr WHERE rr.ZREMINDER4 = r.Z_PK AND rr.ZMARKEDFORDELETION = 0 AND rr.Z_ENT = \(ent) ORDER BY rr.Z_PK LIMIT 1) AS \(alias)"
        }.joined(separator: ", ")
    }

    public func remCols() -> String {
        // Built via array-join to guarantee a clean single-line SQL fragment with
        // no embedded newlines and correct single-space separation between tokens.
        let parts: [String] = [
            "r.Z_PK, r.ZTITLE, r.ZNOTES, r.ZCOMPLETED, r.ZFLAGGED, r.ZPRIORITY",
            "\(urgentColumnExpr()) AS ZISURGENTSTATEENABLEDFORCURRENTUSER",
            "\(dueDateDeltaAlertsExpr()) AS ZDUEDATEDELTAALERTSDATA",
            "r.ZDUEDATE AS ZDUEDATE",
            "\(displayDueExpr()) AS ZDISPLAYDATEDATE",
            "r.ZALLDAY, r.ZCOMPLETIONDATE, r.ZCREATIONDATE, r.ZPARENTREMINDER, r.ZLIST",
            "r.ZICSURL, r.ZCKIDENTIFIER, l.ZNAME as list_name",
            recurrenceCols,
        ]
        return parts.joined(separator: ", ") + timeZoneColumn()
    }
}
