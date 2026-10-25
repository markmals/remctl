import Foundation

/// Port of is_grocery_list_row.
public func isGroceryListRow(_ row: ReminderRow) -> Bool {
    (row.int("ZSHOULDCATEGORIZEGROCERYITEMS") ?? 0) != 0
}

/// Port of is_group_list_row: a Reminders list group, which holds lists instead of reminders.
public func isGroupListRow(_ row: ReminderRow) -> Bool {
    (row.int("ZISGROUP") ?? 0) != 0
}

/// Port of list_parent_pk: the group a list belongs to. Reminders has used both ZPARENTLIST and
/// ZPARENTLIST1 for that reference, so the first one carrying a value wins.
public func listParentPk(_ row: ReminderRow) -> Int? {
    for key in ["ZPARENTLIST", "ZPARENTLIST1"] {
        if let value = row.int(key), value != 0 { return value }
    }
    return nil
}

/// Port of list_child_sort_value: a child list's position inside its group. Reminders writes
/// newer ordered positions as larger sparse keys, so `listChildPrecedes` sorts them descending.
private func listChildSortValue(_ row: ReminderRow) -> Int {
    for key in ["Z_FOK_PARENTLIST", "Z_FOK_PARENTLIST1", "ZDADISPLAYORDER"] {
        if let value = row.int(key), value != 0 { return value }
    }
    return 0
}

/// Port of list_child_sort_key: order inside a group, then normalized title, then id.
public func listChildPrecedes(_ a: ReminderRow, _ b: ReminderRow) -> Bool {
    let (oa, ob) = (-listChildSortValue(a), -listChildSortValue(b))
    if oa != ob { return oa < ob }
    let (na, nb) = (normalizeListLookupName(a.string("ZNAME") ?? ""), normalizeListLookupName(b.string("ZNAME") ?? ""))
    if na != nb { return na < nb }
    return (a.int("Z_PK") ?? 0) < (b.int("Z_PK") ?? 0)
}

/// Port of list_row_title_sort_key: normalized title, then id.
public func listTitlePrecedes(_ a: ReminderRow, _ b: ReminderRow) -> Bool {
    let (na, nb) = (normalizeListLookupName(a.string("ZNAME") ?? ""), normalizeListLookupName(b.string("ZNAME") ?? ""))
    if na != nb { return na < nb }
    return (a.int("Z_PK") ?? 0) < (b.int("Z_PK") ?? 0)
}

/// Active/completed/total reminder counts a group reports for itself and its child lists.
public struct ListReminderCounts {
    public var active: Int
    public var completed: Int
    public var total: Int

    public init(active: Int = 0, completed: Int = 0, total: Int = 0) {
        self.active = active
        self.completed = completed
        self.total = total
    }

    public var payload: JSONValue {
        .object([("active", .int(active)), ("completed", .int(completed)), ("total", .int(total))])
    }
}

/// Index of a `CFKeyedArchiverUID` inside the archive's `$objects` array.
///
/// `PropertyListSerialization` surfaces a binary-plist UID as an opaque CoreFoundation object:
/// it is not an `NSNumber`, is not KVC-compliant, and has no public accessor. Its index is only
/// reachable through the `{value = N}` tail of its CoreFoundation description.
private func archivedUIDIndex(_ value: Any) -> Int? {
    let text = String(describing: value)
    guard text.hasPrefix("<CFKeyedArchiverUID"), let marker = text.range(of: "{value = ") else { return nil }
    return Int(text[marker.upperBound...].prefix(while: \.isNumber))
}

/// Port of parse_list_color (ZCOLOR NSKeyedArchiver binary plist -> {name, hex}).
/// Default fallback is {"blue","#007AFF"}, which is also what an unreadable or incomplete
/// archive yields.
public func parseListColor(_ blob: Data?) -> (name: String, hex: String) {
    let fallback = (name: "blue", hex: "#007AFF")
    guard let blob, !blob.isEmpty else { return fallback }
    guard let plist = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
          let dict = plist as? [String: Any],
          let objects = dict["$objects"] as? [Any] else { return fallback }
    /// Port of upstream's `decode_string`: follow a UID into `$objects`, then unwrap an archived
    /// string object (`{NS.string: …}`), whose payload may itself be a UID.
    func decodeString(_ value: Any) -> String? {
        var current = value
        if let idx = archivedUIDIndex(current), objects.indices.contains(idx) { current = objects[idx] }
        if let wrapper = current as? [String: Any] {
            guard let inner = wrapper["NS.string"] else { return nil }
            current = inner
            if let idx = archivedUIDIndex(current), objects.indices.contains(idx) { current = objects[idx] }
        }
        return current as? String
    }
    for case let object as [String: Any] in objects {
        guard let nameValue = object["ckSymbolicColorName"] else { continue }
        guard let name = decodeString(nameValue) else { return fallback }
        guard let hex = object["daHexString"].map(decodeString) ?? "" else { return fallback }
        return (name, hex)
    }
    return fallback
}

/// Port of parse_badge_emblem (ZBADGEEMBLEM string -> ordered {raw, [emoji], [symbol]} or nil).
public func parseBadgeEmblem(_ value: String?) -> [(String, JSONValue)]? {
    guard let value, !value.isEmpty else { return nil }
    var payload: [(String, JSONValue)] = [("raw", .string(value))]
    let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.hasPrefix("{") {
        if let data = stripped.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let emoji = (decoded["Emoji"] ?? decoded["emoji"]) as? String, !emoji.isEmpty {
                payload.append(("emoji", .string(emoji)))
            }
            if let emblem = (decoded["Emblem"] ?? decoded["emblem"]) as? String, !emblem.isEmpty {
                payload.append(("symbol", .string(emblem)))
            }
        }
    } else if !stripped.isEmpty {
        payload.append(("symbol", .string(stripped)))
    }
    return payload
}

/// Port of grocery_list_payload (ordered) or nil when no grocery columns are present on the row.
public func groceryListPayload(_ row: ReminderRow) -> [(String, JSONValue)]? {
    let keys = ["ZSHOULDCATEGORIZEGROCERYITEMS", "ZSHOULDAUTOCATEGORIZEITEMS",
                "ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST", "ZGROCERYLOCALEID",
                "ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA_LENGTH"]
    guard keys.contains(where: { row.has($0) }) else { return nil }
    var payload: [(String, JSONValue)] = [
        ("shouldCategorizeItems", .bool((row.int("ZSHOULDCATEGORIZEGROCERYITEMS") ?? 0) != 0)),
        ("shouldAutoCategorizeItems", .bool((row.int("ZSHOULDAUTOCATEGORIZEITEMS") ?? 0) != 0)),
        ("shouldSuggestConversion", .bool((row.int("ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST") ?? 0) != 0)),
    ]
    if let locale = row.string("ZGROCERYLOCALEID"), !locale.isEmpty { payload.append(("locale", .string(locale))) }
    if row.has("ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA_LENGTH"),
       let len = row.int("ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA_LENGTH") {
        payload.append(("localCorrectionsLength", .int(len)))
    }
    if let checksum = row.string("ZAUTOCATEGORIZATIONLOCALCORRECTIONSCHECKSUM"), !checksum.isEmpty {
        payload.append(("localCorrectionsChecksum", .string(checksum)))
    }
    return payload
}

private func groceryHasAnyTruthy(_ pairs: [(String, JSONValue)]) -> Bool {
    pairs.contains { _, v in
        switch v {
        case .bool(let b): return b
        case .string(let s): return !s.isEmpty
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        default: return false
        }
    }
}

/// Port of list_to_dict — ordered keys: id, title, listType, isGroup, isGroceries, [objectUUID],
/// [parentListId], [color], [badge, badgeEmblem], [grocery], [pinned], [pinnedDate].
public func listToDict(_ row: ReminderRow) -> [(String, JSONValue)] {
    let isGroup = isGroupListRow(row)
    let isGroceries = isGroceryListRow(row)
    var item: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("title", row.string("ZNAME").map { .string($0) } ?? .null),
        ("listType", .string(isGroup ? "group" : isGroceries ? "groceries" : "standard")),
        ("isGroup", .bool(isGroup)),
        ("isGroceries", .bool(!isGroup && isGroceries)),
    ]
    if let uuid = row.string("ZCKIDENTIFIER"), !uuid.isEmpty { item.append(("objectUUID", .string(uuid))) }
    if let parentId = listParentPk(row) { item.append(("parentListId", .int(parentId))) }
    if row.has("ZCOLOR"), let blob = row.data("ZCOLOR"), !blob.isEmpty {
        let c = parseListColor(blob)
        item.append(("color", .object([("name", .string(c.name)), ("hex", .string(c.hex))])))
    }
    if row.has("ZBADGEEMBLEM"), let raw = row.string("ZBADGEEMBLEM"), !raw.isEmpty {
        if let badge = parseBadgeEmblem(raw) { item.append(("badge", .object(badge))) }
        item.append(("badgeEmblem", .string(raw)))
    }
    // A group is a container: Reminders never gives it grocery metadata of its own.
    if let grocery = groceryListPayload(row), !isGroup, isGroceries || groceryHasAnyTruthy(grocery) {
        item.append(("grocery", .object(grocery)))
    }
    if row.has("ZISPINNEDBYCURRENTUSER") {
        item.append(("pinned", .bool((row.int("ZISPINNEDBYCURRENTUSER") ?? 0) != 0)))
    }
    if row.has("ZPINNEDDATE"), let pd = row.double("ZPINNEDDATE") {
        item.append(("pinnedDate", .double(pd)))
    }
    return item
}

/// Port of list_group_stub: how a group is named from one of its child lists (and how a child
/// list is named from a reminder in it).
public func listGroupStub(_ row: ReminderRow) -> [(String, JSONValue)] {
    var payload: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("title", row.string("ZNAME").map { .string($0) } ?? .null),
    ]
    if let uuid = row.string("ZCKIDENTIFIER"), !uuid.isEmpty { payload.append(("objectUUID", .string(uuid))) }
    return payload
}

/// Port of split_list_group_rows: groups (by title), each group's child lists (in child order),
/// and the lists that belong to no group (by title).
public func splitListGroupRows<Row: ReminderRow>(_ rows: [Row])
    -> (groups: [Row], children: [Int: [Row]], ungrouped: [Row])
{
    let groups = rows.filter(isGroupListRow).sorted(by: listTitlePrecedes)
    let groupIds = Set(groups.map { $0.int("Z_PK") ?? 0 })
    var children: [Int: [Row]] = [:]
    for id in groupIds { children[id] = [] }
    var ungrouped: [Row] = []
    for row in rows where !isGroupListRow(row) {
        if let parentId = listParentPk(row), groupIds.contains(parentId) {
            children[parentId, default: []].append(row)
        } else {
            ungrouped.append(row)
        }
    }
    for id in children.keys { children[id] = children[id]?.sorted(by: listChildPrecedes) }
    return (groups, children, ungrouped.sorted(by: listTitlePrecedes))
}

/// Port of group_payload_from_rows: a group payload whose `children` carry their group stub and
/// reminder counts, with the group's own counts summed from them.
public func groupPayloadFromRows(_ groupRow: ReminderRow, children childRows: [ReminderRow],
                                 counts: [Int: ListReminderCounts]) -> [(String, JSONValue)]
{
    var group = listToDict(groupRow)
    let stub = listGroupStub(groupRow)
    var totals = ListReminderCounts()
    var children: [JSONValue] = []
    for childRow in childRows {
        var child = listToDict(childRow)
        child.append(("group", .object(stub)))
        let childCounts = counts[childRow.int("Z_PK") ?? 0] ?? ListReminderCounts()
        child.append(("counts", childCounts.payload))
        totals.active += childCounts.active
        totals.completed += childCounts.completed
        totals.total += childCounts.total
        children.append(.object(child))
    }
    group.append(("counts", totals.payload))
    group.append(("children", .array(children)))
    return group
}

/// Port of list_hierarchy_payloads for `lists --json`: every group with its children nested,
/// each child repeated at the top level (so a flat scan still sees every list), then the lists
/// that belong to no group.
public func listHierarchyPayloads<Row: ReminderRow>(_ rows: [Row],
                                                    counts: [Int: ListReminderCounts]) -> [JSONValue]
{
    let (groups, childRows, ungrouped) = splitListGroupRows(rows)
    var payloads: [JSONValue] = []
    for groupRow in groups {
        let children = childRows[groupRow.int("Z_PK") ?? 0] ?? []
        let group = groupPayloadFromRows(groupRow, children: children, counts: counts)
        payloads.append(.object(group))
        for (key, value) in group where key == "children" {
            if case let .array(childPayloads) = value { payloads.append(contentsOf: childPayloads) }
        }
    }
    payloads.append(contentsOf: ungrouped.map { .object(listToDict($0)) })
    return payloads
}
