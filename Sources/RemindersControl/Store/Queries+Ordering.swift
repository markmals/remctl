import GRDB
import Foundation

/// A smart list's persisted manual order (a `REMCDManualSortHint_v1` row), the record that
/// `reminder-move --smart-list` rewrites.
public struct ManualSortHint: Equatable {
    public let objectUUID: String
    public let topLevelElementIDs: [String]
    public let secondaryLevelElementIDs: [String: [String]]
}

extension RemindersStore {
    /// `ZLISTTYPERAWVALUE` of a custom smart list's manual-order hint.
    static let customSmartListManualOrderType = 2

    /// Port of `q_manual_sort_hint`: the newest live hint for `listId`. Nil when the store has no
    /// hint entity or columns, no hint for the list, or a payload that does not decode.
    public func manualSortHint(listType: Int, listId: String) -> ManualSortHint? {
        let entity = entityID("REMCDManualSortHint_v1", fallback: -1)
        let columns = tableColumnNames("ZREMCDOBJECT")
        guard entity >= 0, ["ZLISTTYPERAWVALUE", "ZLISTID", "ZHINTDATA"].allSatisfy(columns.contains) else { return nil }
        let row = try? queue.read { try Row.fetchOne($0, sql: """
            SELECT ZCKIDENTIFIER, ZHINTDATA FROM ZREMCDOBJECT
            WHERE +Z_ENT = ? AND +ZMARKEDFORDELETION = 0 AND ZLISTTYPERAWVALUE = ? AND lower(ZLISTID) = lower(?)
            ORDER BY Z_PK DESC LIMIT 1
            """, arguments: [entity, listType, listId]) }
        guard let row, let identifier = row.string("ZCKIDENTIFIER"), !identifier.isEmpty,
              let payload = decodeManualSortHint(row["ZHINTDATA"]) else { return nil }
        return ManualSortHint(objectUUID: identifier, topLevelElementIDs: payload.topLevel,
                              secondaryLevelElementIDs: payload.secondary)
    }
}

/// Port of `decode_manual_sort_hint_blob`: JSON after an optional leading 0x01 byte, with string
/// top-level ids and a string-array map for the second level. Anything else is unreadable.
func decodeManualSortHint(_ value: DatabaseValue?) -> (topLevel: [String], secondary: [String: [String]])? {
    var data: Data
    switch value?.storage {
    case .blob(let blob)?: data = blob
    case .string(let text)?: data = Data(text.utf8)
    default: return nil
    }
    if data.first == 0x01 { data = data.dropFirst() }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let topLevel = object["topLevelElementIDs"] ?? [Any]()
    let secondary = object["secondaryLevelElementIDsByTopLevelElementID"] ?? [String: Any]()
    guard let ids = topLevel as? [String], ids.allSatisfy({ !$0.isEmpty }),
          let map = secondary as? [String: [String]], map.values.allSatisfy({ $0.allSatisfy { !$0.isEmpty } })
    else { return nil }
    return (ids, map)
}

/// Port of `reorder_identifier_list`: `ordering` with `moving` placed before/after `anchor`, or
/// first/last. Nil when a relative move's anchor is not in the ordering. Identifiers compare
/// case-insensitively; the ordering keeps its own spelling.
func reorderIdentifiers(_ ordering: [String], moving: String, position: String, anchor: String?) -> [String]? {
    let folded = unicodeCasefold(moving)
    let movingID = ordering.first { unicodeCasefold($0) == folded } ?? moving
    var result = ordering.filter { unicodeCasefold($0) != folded }
    let index: Int
    switch position {
    case "first": index = 0
    case "last": index = result.count
    default:
        guard let anchor, let anchorIndex = result.firstIndex(where: { unicodeCasefold($0) == unicodeCasefold(anchor) }) else {
            return nil
        }
        index = anchorIndex + (position == "after" ? 1 : 0)
    }
    result.insert(movingID, at: index)
    return result
}
