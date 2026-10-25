import Foundation

/// One of a custom smart list's own sections, as `--smart-list` with `--section`/`--section-id`
/// names it.
public struct SmartListSection: Equatable, Sendable {
    public let sectionId: String
    public let section: String
    public let smartListId: String
    public let smartListPk: Int
    public let smartList: String
}

/// Where `--section`/`--section-id` points, resolved once before anything is written so the write
/// lands on the section that was validated (upstream caf7423, c6a2429).
public enum SectionTarget: Equatable, Sendable {
    /// A section of the reminder's list, by stable identifier.
    case list(sectionId: String)
    case smartList(SmartListSection)
}

/// Port of `validate_private_args`' smart-list checks and `resolve_section_target`. Nil when no
/// section was asked for. Without `--smart-list`/`--smart-list-id` the section always belongs to
/// the reminder's list (`listPk`).
func resolveSectionTarget(store: RemindersStore, listPk: Int?, section: String?, sectionId: String?,
                          newSection: String?, smartList: String?, smartListId: Int?) throws -> SectionTarget? {
    let smartTargeted = (smartList?.isEmpty == false) || smartListId != nil
    if smartTargeted {
        if section == nil && sectionId == nil {
            throw CLIError("--smart-list and --smart-list-id need --section or --section-id.", code: "invalid_section_target")
        }
        if section != nil && sectionId != nil {
            throw CLIError("pass either --section or --section-id, not both.", code: "invalid_section_target")
        }
        if newSection != nil {
            throw CLIError("--new-section creates a section in the reminder's list; it cannot be combined with --smart-list.",
                           code: "invalid_section_target")
        }
        return .smartList(try resolveSmartListSection(store: store, smartList: smartList, smartListId: smartListId,
                                                      section: section, sectionId: sectionId))
    }
    guard let ckid = try store.resolveSectionCkid(listPk: listPk ?? 0, section: section, sectionId: sectionId) else {
        return nil
    }
    return .list(sectionId: ckid)
}

/// Port of `resolve_smart_list_section_or_die`: `--section`/`--section-id` among the sections of
/// the custom smart list `--smart-list`/`--smart-list-id` names.
private func resolveSmartListSection(store: RemindersStore, smartList: String?, smartListId: Int?,
                                     section: String?, sectionId: String?) throws -> SmartListSection {
    let target = try resolveSmartListTarget(store: store, name: smartList, smartListId: smartListId)
    guard target.isCustom, let smartListCkid = target.objectUUID else {
        throw CLIError("\(WriteFormatting.pyRepr(target.title)) is a built-in smart list; only custom smart lists have sections.",
                       code: "smart_list_not_custom")
    }
    let sections = store.smartListSections(smartListPk: target.id).filter { !($0.string("ZCKIDENTIFIER") ?? "").isEmpty }
    let normalizedId = sectionId.flatMap { PrivateParsing.normalizeSectionId($0) }
    let matches = sections.filter { row in
        if let normalizedId { return (row.string("ZCKIDENTIFIER") ?? "").lowercased() == normalizedId.lowercased() }
        return (row.string("ZDISPLAYNAME") ?? "").lowercased() == (section ?? "").lowercased()
    }
    guard matches.count == 1, let match = matches.first else {
        let options = (matches.isEmpty ? sections : matches).map {
            "\(WriteFormatting.pyRepr($0.string("ZDISPLAYNAME") ?? "")) (\($0.string("ZCKIDENTIFIER") ?? ""))"
        }.joined(separator: ", ")
        let (problem, hint, code) = matches.isEmpty
            ? ("section not found: \(normalizedId ?? section ?? "")", "Its sections are", "section_not_found")
            : ("multiple sections named \(WriteFormatting.pyRepr(section ?? ""))", "Use --section-id with one of", "section_ambiguous")
        throw CLIError("\(problem) in smart list \(WriteFormatting.pyRepr(target.title)). \(hint): \(options.isEmpty ? "none" : options)",
                       code: code)
    }
    return SmartListSection(sectionId: match.string("ZCKIDENTIFIER") ?? "", section: match.string("ZDISPLAYNAME") ?? "",
                            smartListId: smartListCkid, smartListPk: target.id, smartList: target.title)
}
