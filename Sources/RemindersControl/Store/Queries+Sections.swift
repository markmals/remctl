import GRDB
import Foundation

extension RemindersStore {
    /// All sections ordered by list name then Z_PK, with list_name joined in.
    public func sectionsAll() -> [Row] {
        let sql = """
        SELECT s.Z_PK, s.ZDISPLAYNAME, s.ZLIST, s.ZCKIDENTIFIER, l.ZNAME as list_name
        FROM ZREMCDBASESECTION s
        LEFT JOIN ZREMCDBASELIST l ON s.ZLIST = l.Z_PK
        WHERE s.ZMARKEDFORDELETION = 0
        ORDER BY l.ZNAME, s.Z_PK
        """
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }

    /// q_sections for a specific list (remctl:1306): sections not deleted, ORDER BY Z_PK.
    public func sections(listPk: Int) -> [Row] {
        let sql = """
        SELECT Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER
        FROM ZREMCDBASESECTION
        WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ?
        ORDER BY Z_PK
        """
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [listPk]) }) ?? []
    }

    /// q_section_member_counts (remctl:1339): counts per section CKID from the
    /// `ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` JSON blob on the list row.
    /// Non-obsolete memberships only. Returns empty dict if blob is absent/invalid.
    public func sectionMemberCounts(listPk: Int) -> [String: Int] {
        guard let row = try? queue.read({ try Row.fetchOne($0, sql:
            "SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST WHERE Z_PK = ?",
            arguments: [listPk]) }),
              let blob = row.string("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA"),
              let data = blob.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memberships = parsed["memberships"] as? [[String: Any]]
        else { return [:] }

        var counts: [String: Int] = [:]
        for membership in memberships {
            if let isObsolete = membership["isObsolete"] as? Bool, isObsolete { continue }
            if let groupId = membership["groupID"] as? String,
               let memberId = membership["memberID"] as? String,
               !groupId.isEmpty, !memberId.isEmpty {
                counts[groupId, default: 0] += 1
            }
        }
        return counts
    }

    /// Port of `resolve_section_ckid` (remctl:2803).
    /// - If `sectionId` given: normalizes it and looks up by ZLIST + lower(ZCKIDENTIFIER).
    /// - If `section` (display name) given: looks up by display name in the list, disambiguates
    ///   duplicate names via member counts (unique non-empty → use it; else → throws with options).
    /// - Both nil → returns nil.
    /// Throws `CLIError` for not-found, ambiguous, both-given, or missing list.
    public func resolveSectionCkid(listPk: Int, section: String? = nil, sectionId: String? = nil) throws -> String? {
        let normalizedId = sectionId.flatMap { PrivateParsing.normalizeSectionId($0) }

        if section != nil && normalizedId != nil {
            throw CLIError("pass either --section or --section-id, not both.")
        }
        guard section != nil || normalizedId != nil else { return nil }

        // Validate we have a list
        // (callers who have no list_pk should pass 0, which will never match)

        if let secId = normalizedId {
            // Lookup by section ID (case-insensitive CKID match)
            let row = try? queue.read { try Row.fetchOne($0, sql:
                "SELECT ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZLIST = ? AND ZMARKEDFORDELETION = 0 AND lower(ZCKIDENTIFIER) = lower(?)",
                arguments: [listPk, secId]) }
            guard let ckid = row?.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
                throw CLIError("section ID not found in target list: \(secId)")
            }
            return ckid
        }

        // Lookup by display name
        let sectionName = section!
        let allSections = sections(listPk: listPk)
        var matches = allSections.filter {
            ($0.string("ZDISPLAYNAME") ?? "").lowercased() == sectionName.lowercased()
        }

        if matches.isEmpty {
            throw CLIError("section not found in target list: \(sectionName)")
        }
        if matches.count > 1 {
            // Disambiguate via member counts
            let counts = sectionMemberCounts(listPk: listPk)
            let nonEmpty = matches.filter { (counts[$0.string("ZCKIDENTIFIER") ?? ""] ?? 0) > 0 }
            if nonEmpty.count == 1 {
                matches = nonEmpty
            } else {
                let options = matches.map { row -> String in
                    let ckid = row.string("ZCKIDENTIFIER") ?? ""
                    let count = counts[ckid] ?? 0
                    let noun = count == 1 ? "reminder" : "reminders"
                    return "\(ckid) (\(count) \(noun))"
                }.joined(separator: ", ")
                throw CLIError("multiple sections named \(pyRepr(sectionName)) in target list. Use --section-id with one of: \(options)")
            }
        }

        guard let ckid = matches[0].string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            throw CLIError("section has no stable CloudKit identifier: \(sectionName)")
        }
        return ckid
    }

    /// Python-style repr for a string (single-quoted).
    private func pyRepr(_ s: String) -> String {
        "'\(s)'"
    }
}
