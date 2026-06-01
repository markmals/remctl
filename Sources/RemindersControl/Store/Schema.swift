import Foundation

public enum Zent {
    public static let list = 3, smartList = 4, alarm = 15, recurrence = 34
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
    /// Port of `due_filter_expr`. Date used for due-window bucketing/ordering.
    /// Reminders stores all-day items with a synthetic ZDUEDATE (UTC midnight), while
    /// ZDISPLAYDATEDATE is the local day Reminders.app displays. West of UTC the synthetic
    /// timestamp lands on the previous local day, so all-day items must bucket by the
    /// display date. Falls back to plain ZDUEDATE when either column is absent.
    func dueFilterExpr(_ alias: String = "r") -> String {
        let due = "\(alias).ZDUEDATE"
        guard reminderHasColumn("ZALLDAY"), reminderHasColumn("ZDISPLAYDATEDATE") else { return due }
        return "(CASE WHEN \(alias).ZALLDAY = 1 THEN COALESCE(\(alias).ZDISPLAYDATEDATE, \(due)) ELSE \(due) END)"
    }

    /// 10 correlated subqueries on ZREMCDOBJECT (Z_ENT=34, FK ZREMINDER4). Aliases are read by the serializer.
    var recurrenceCols: String {
        let pairs: [(String, String)] = [
            ("ZFREQUENCY", "recurrence_frequency"), ("ZINTERVAL", "recurrence_interval"),
            ("ZOCCURRENCECOUNT", "recurrence_count"), ("ZENDDATE", "recurrence_end_date"),
            ("ZDAYSOFTHEWEEK", "recurrence_days_of_week"), ("ZDAYSOFTHEMONTH", "recurrence_days_of_month"),
            ("ZMONTHSOFTHEYEAR", "recurrence_months_of_year"), ("ZDAYSOFTHEYEAR", "recurrence_days_of_year"),
            ("ZWEEKSOFTHEYEAR", "recurrence_weeks_of_year"), ("ZSETPOSITIONS", "recurrence_set_positions"),
        ]
        return pairs.map { col, alias in
            "(SELECT rr.\(col) FROM ZREMCDOBJECT rr WHERE rr.ZREMINDER4 = r.Z_PK AND rr.ZMARKEDFORDELETION = 0 AND rr.Z_ENT = \(Zent.recurrence) ORDER BY rr.Z_PK LIMIT 1) AS \(alias)"
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
        return parts.joined(separator: ", ")
    }
}
