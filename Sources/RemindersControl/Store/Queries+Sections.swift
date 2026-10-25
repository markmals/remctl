import GRDB
import Foundation

/// Sections whose list still exists and is not deleted, ordered by list name then Z_PK.
private let liveSectionsSQL = """
SELECT s.Z_PK, s.ZDISPLAYNAME, s.ZLIST, s.ZCKIDENTIFIER, l.ZNAME as list_name
FROM ZREMCDBASESECTION s
JOIN ZREMCDBASELIST l ON s.ZLIST = l.Z_PK
WHERE s.ZMARKEDFORDELETION = 0 AND l.ZMARKEDFORDELETION = 0
ORDER BY l.ZNAME, s.Z_PK
"""

extension RemindersStore {
    /// All sections of a LIVE list, ordered by list name then Z_PK, with list_name joined in.
    /// Deleting a list can leave its sections behind with no list at all; Reminders hides them,
    /// and so does RemCTL. Smart-list and template sections have no ZLIST and are read through
    /// their own commands.
    public func sectionsAll() -> [Row] {
        return (try? queue.read { try Row.fetchAll($0, sql: liveSectionsSQL) }) ?? []
    }

    /// Count of the same live sections (`stats`' Sections line).
    public func liveSectionCount() -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM (\(liveSectionsSQL))") ?? 0 }) ?? 0
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

    /// Port of `q_smart_list_sections`: the live sections a custom smart list owns (its rows in
    /// ZREMCDBASESECTION carry ZSMARTLIST instead of ZLIST). Stores without the column have none.
    public func smartListSections(smartListPk: Int) -> [Row] {
        guard tableColumnNames("ZREMCDBASESECTION").contains("ZSMARTLIST") else { return [] }
        return (try? queue.read { try Row.fetchAll($0, sql: """
            SELECT Z_PK, ZDISPLAYNAME, ZSMARTLIST, ZCKIDENTIFIER FROM ZREMCDBASESECTION
            WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLIST = ? ORDER BY Z_PK
            """, arguments: [smartListPk]) }) ?? []
    }

    /// A list's live section identifiers in Reminders' display order: the list's persisted
    /// `ZSECTIONIDSORDERINGASDATA` record first, then live sections it does not mention yet, in
    /// Z_PK order. Writes that add a section append to this, so they keep the user's order.
    public func sectionOrder(listPk: Int) -> [String] {
        let live = sections(listPk: listPk).compactMap { $0.string("ZCKIDENTIFIER") }.filter { !$0.isEmpty }
        var byFolded: [String: String] = [:]
        for identifier in live { byFolded[unicodeCasefold(identifier)] = identifier }
        var ordered: [String] = []
        for identifier in persistedSectionOrder(listPk: listPk) {
            if let match = byFolded.removeValue(forKey: unicodeCasefold(identifier)) { ordered.append(match) }
        }
        return ordered + live.filter { byFolded[unicodeCasefold($0)] != nil }
    }

    /// `orderedIdentifiers` of the list's section-ordering record; empty when the column, row, or
    /// payload is missing or unreadable.
    private func persistedSectionOrder(listPk: Int) -> [String] {
        guard tableColumnNames("ZREMCDBASELIST").contains("ZSECTIONIDSORDERINGASDATA"),
              let row = try? queue.read({ try Row.fetchOne($0, sql:
                  "SELECT ZSECTIONIDSORDERINGASDATA FROM ZREMCDBASELIST WHERE Z_PK = ?", arguments: [listPk]) }),
              let text = row.blobString("ZSECTIONIDSORDERINGASDATA"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let identifiers = object["orderedIdentifiers"] as? [Any]
        else { return [] }
        return identifiers.compactMap { $0 as? String }
    }

    /// Port of `section_name_exists`: whether another live section of the list already carries
    /// `name` (case-folded), ignoring the section `excluding` names.
    public func sectionNameExists(listPk: Int, name: String, excluding: String? = nil) -> Bool {
        let needle = unicodeCasefold(name)
        let excluded = excluding.map(unicodeCasefold)
        return sections(listPk: listPk).contains { row in
            let identifier = unicodeCasefold(row.string("ZCKIDENTIFIER") ?? "")
            return identifier != excluded && unicodeCasefold(row.string("ZDISPLAYNAME") ?? "") == needle
        }
    }

    /// The live section `identifier` names in the list, or nil when it is gone.
    public func liveSection(listPk: Int, identifier: String) -> Row? {
        let folded = unicodeCasefold(identifier)
        return sections(listPk: listPk).first { unicodeCasefold($0.string("ZCKIDENTIFIER") ?? "") == folded }
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
            throw CLIError("pass either --section or --section-id, not both.", code: "invalid_section_target")
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
                throw CLIError("section ID not found in target list: \(secId)", code: "section_not_found")
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
            throw CLIError("section not found in target list: \(sectionName)", code: "section_not_found")
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
                throw CLIError("multiple sections named \(pyRepr(sectionName)) in target list. Use --section-id with one of: \(options)",
                               code: "section_ambiguous")
            }
        }

        guard let ckid = matches[0].string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            throw CLIError("section has no stable CloudKit identifier: \(sectionName)", code: "section_missing_identifier")
        }
        return ckid
    }

    /// Python-style repr for a string (single-quoted).
    private func pyRepr(_ s: String) -> String {
        "'\(s)'"
    }
}
