import Foundation
import GRDB

// ──────────────────────────────────────────────────────────────────────────────
// Sharee / assignment queries — port of upstream 683c362 (q_sharees,
// q_list_shared_owner_ckid, q_assignment, sharee_to_dict, assignment_to_dict)
// with the aba7cf5 case-insensitive CKID matching fix folded in.
// ──────────────────────────────────────────────────────────────────────────────

extension RemindersStore {
    /// q_sharees (remctl:1545): a shared list's participant objects (Z_ENT=36),
    /// ORDER BY Z_PK. Empty for unshared lists.
    public func sharees(listPk: Int) -> [Row] {
        (try? queue.read { try Row.fetchAll($0, sql:
            "SELECT Z_PK, ZCKIDENTIFIER, ZDISPLAYNAME, ZFIRSTNAME, ZLASTNAME, ZADDRESS1, "
            + "ZSTATUS, ZACCESSLEVEL FROM ZREMCDOBJECT "
            + "WHERE Z_ENT = \(Zent.sharee) AND ZMARKEDFORDELETION = 0 AND ZLIST = ? "
            + "ORDER BY Z_PK",
            arguments: [listPk]) }) ?? []
    }

    /// q_list_shared_owner_ckid (remctl:1116): the current user's sharee CKID for a
    /// shared list, decoded from the ZSHAREDOWNERIDENTIFIER UUID blob (uppercase).
    /// nil when the column is missing (older schema) or the list isn't shared.
    public func listSharedOwnerCkid(listPk: Int) -> String? {
        guard tableColumnNames("ZREMCDBASELIST").contains("ZSHAREDOWNERIDENTIFIER") else { return nil }
        let row = (try? queue.read { try Row.fetchOne($0, sql:
            "SELECT ZSHAREDOWNERIDENTIFIER FROM ZREMCDBASELIST "
            + "WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = \(Zent.list)",
            arguments: [listPk]) }) ?? nil
        guard let row else { return nil }
        return uuidFromBlob(row.data("ZSHAREDOWNERIDENTIFIER"))
    }

    /// q_assignment (remctl:1556): the newest live assignment object (Z_ENT=21) for a
    /// reminder, joined to its assignee/originator sharee rows. nil when the reminder
    /// has no assignment or the schema lacks the assignment columns (older macOS).
    public func assignment(reminderPk: Int) -> Row? {
        (try? queue.read { try Row.fetchOne($0, sql:
            "SELECT a.Z_PK, a.ZCKIDENTIFIER, a.ZSTATUS, a.ZASSIGNEDDATE, "
            + "a.ZCKASSIGNEEIDENTIFIER, a.ZCKORIGINATORIDENTIFIER, "
            + "assignee.Z_PK AS assignee_pk, assignee.ZCKIDENTIFIER AS assignee_ckid, "
            + "assignee.ZDISPLAYNAME AS assignee_display, assignee.ZFIRSTNAME AS assignee_first, "
            + "assignee.ZLASTNAME AS assignee_last, assignee.ZADDRESS1 AS assignee_address, "
            + "originator.Z_PK AS originator_pk, originator.ZCKIDENTIFIER AS originator_ckid, "
            + "originator.ZDISPLAYNAME AS originator_display, originator.ZFIRSTNAME AS originator_first, "
            + "originator.ZLASTNAME AS originator_last, originator.ZADDRESS1 AS originator_address "
            + "FROM ZREMCDOBJECT a "
            + "LEFT JOIN ZREMCDOBJECT assignee ON a.ZASSIGNEE = assignee.Z_PK "
            + "LEFT JOIN ZREMCDOBJECT originator ON a.ZORIGINATOR = originator.Z_PK "
            + "WHERE a.Z_ENT = \(Zent.assignment) AND a.ZMARKEDFORDELETION = 0 AND a.ZREMINDER1 = ? "
            + "ORDER BY a.ZASSIGNEDDATE DESC, a.Z_PK DESC LIMIT 1",
            arguments: [reminderPk]) }) ?? nil
    }
}

/// Port of `ckid_eq` (upstream aba7cf5): case-insensitive CKID compare. False when
/// either side is missing or empty — sharee CKIDs are stored lowercase in some rows
/// while the owner blob decodes to uppercase, so exact compare misidentifies "me".
public func ckidEq(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
    return unicodeCasefold(a) == unicodeCasefold(b)
}

/// Port of `_sharee_display_name` (remctl:1534): ZDISPLAYNAME, else "First Last",
/// else ZADDRESS1, else "".
public func shareeDisplayName(_ row: ReminderRow) -> String {
    if let display = row.string("ZDISPLAYNAME"), !display.isEmpty { return display }
    let parts = [row.string("ZFIRSTNAME"), row.string("ZLASTNAME")]
        .compactMap { $0 }.filter { !$0.isEmpty }
    if !parts.isEmpty { return parts.joined(separator: " ") }
    return row.string("ZADDRESS1") ?? ""
}

/// Port of `sharee_to_dict` (remctl:803): ordered keys id, objectUUID, name,
/// [displayName, firstName, lastName, address], [status], [accessLevel], [currentUser].
public func shareeToDict(_ row: ReminderRow, currentUserCkid: String?) -> [(String, JSONValue)] {
    var payload: [(String, JSONValue)] = [
        ("id", row.int("Z_PK").map(JSONValue.int) ?? .null),
        ("objectUUID", row.string("ZCKIDENTIFIER").map(JSONValue.string) ?? .null),
        ("name", .string(shareeDisplayName(row))),
    ]
    for (source, output) in [("ZDISPLAYNAME", "displayName"), ("ZFIRSTNAME", "firstName"),
                             ("ZLASTNAME", "lastName"), ("ZADDRESS1", "address")] {
        if let value = row.string(source), !value.isEmpty {
            payload.append((output, .string(value)))
        }
    }
    if let status = row.int("ZSTATUS") { payload.append(("status", .int(status))) }
    if let level = row.int("ZACCESSLEVEL") { payload.append(("accessLevel", .int(level))) }
    if ckidEq(row.string("ZCKIDENTIFIER"), currentUserCkid) {
        payload.append(("currentUser", .bool(true)))
    }
    return payload
}

/// Port of `assignment_to_dict` (remctl:921): {id, objectUUID, status, assignee{...},
/// originator{...}, [assignedDate]} built from the q_assignment joined row.
public func assignmentToDict(_ row: ReminderRow?) -> JSONValue? {
    guard let row else { return nil }
    func person(_ prefix: String, fallbackCkid: String) -> JSONValue {
        let name = shareeDisplayName(DictShareeRow(row: row, prefix: prefix))
        var pairs: [(String, JSONValue)] = [
            ("id", row.int("\(prefix)_pk").map(JSONValue.int) ?? .null),
            ("objectUUID", (row.string("\(prefix)_ckid") ?? row.string(fallbackCkid)).map(JSONValue.string) ?? .null),
            ("name", .string(name)),
        ]
        if let address = row.string("\(prefix)_address"), !address.isEmpty {
            pairs.append(("address", .string(address)))
        }
        return .object(pairs)
    }
    var payload: [(String, JSONValue)] = [
        ("id", row.int("Z_PK").map(JSONValue.int) ?? .null),
        ("objectUUID", row.string("ZCKIDENTIFIER").map(JSONValue.string) ?? .null),
        ("status", row.int("ZSTATUS").map(JSONValue.int) ?? .null),
        ("assignee", person("assignee", fallbackCkid: "ZCKASSIGNEEIDENTIFIER")),
        ("originator", person("originator", fallbackCkid: "ZCKORIGINATORIDENTIFIER")),
    ]
    if let assigned = row.double("ZASSIGNEDDATE"), assigned != 0 {
        payload.append(("assignedDate", .string(isoLocalDateTime(appleSeconds: assigned))))
    }
    return .object(payload)
}

extension RemindersStore {
    /// The reminder's assignee display name (or nil) — the per-row lookup the human
    /// formatters use for the " @Name" marker (mirrors fmt's q_assignment call).
    public func assignmentAssignee(pk: Int) -> String? {
        assignmentAssigneeName(assignmentToDict(assignment(reminderPk: pk)))
    }
}

/// The "name or objectUUID" label of an assignment person (Python's
/// `assignment.get(key, {}).get("name") or .get("objectUUID")`). nil when both are
/// empty/missing.
public func assignmentPersonLabel(_ assignment: JSONValue?, key: String) -> String? {
    guard case let .object(pairs)? = assignment else { return nil }
    for (k, v) in pairs where k == key {
        guard case let .object(inner) = v else { return nil }
        var name: String? = nil
        var uuid: String? = nil
        for (ik, iv) in inner {
            if ik == "name", case let .string(s) = iv, !s.isEmpty { name = s }
            if ik == "objectUUID", case let .string(s) = iv, !s.isEmpty { uuid = s }
        }
        return name ?? uuid
    }
    return nil
}

/// The assignee display name of a serialized JSON `assignment` (or nil). Convenience
/// for fmt/info callers that only need the "@Name" string.
public func assignmentAssigneeName(_ assignment: JSONValue?) -> String? {
    guard case let .object(pairs)? = assignment else { return nil }
    for (k, v) in pairs where k == "assignee" {
        guard case let .object(inner) = v else { return nil }
        for (ik, iv) in inner where ik == "name" {
            if case let .string(s) = iv, !s.isEmpty { return s }
        }
    }
    return nil
}

/// Adapter exposing the q_assignment row's prefixed person columns under the plain
/// sharee column names, so `shareeDisplayName` can be reused (mirrors the synthetic
/// dict Python passes to `_sharee_display_name`).
private struct DictShareeRow: ReminderRow {
    let row: ReminderRow
    let prefix: String
    private func mapped(_ key: String) -> String {
        switch key {
        case "ZDISPLAYNAME": return "\(prefix)_display"
        case "ZFIRSTNAME": return "\(prefix)_first"
        case "ZLASTNAME": return "\(prefix)_last"
        case "ZADDRESS1": return "\(prefix)_address"
        default: return key
        }
    }
    func has(_ key: String) -> Bool { row.has(mapped(key)) }
    func string(_ key: String) -> String? { row.string(mapped(key)) }
    func int(_ key: String) -> Int? { row.int(mapped(key)) }
    func double(_ key: String) -> Double? { row.double(mapped(key)) }
    func data(_ key: String) -> Data? { row.data(mapped(key)) }
}

/// Apple-epoch seconds → naive-local ISO string (Python `ts(v).isoformat()` for
/// whole-second values).
func isoLocalDateTime(appleSeconds: Double, calendar: Calendar = .current) -> String {
    let date = Date(timeIntervalSince1970: appleSeconds + AppleEpoch.offset)
    let df = DateFormatter()
    df.calendar = calendar
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = calendar.timeZone
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return df.string(from: date)
}
