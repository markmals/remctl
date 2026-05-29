import Foundation

/// Port of is_grocery_list_row.
public func isGroceryListRow(_ row: ReminderRow) -> Bool {
    (row.int("ZSHOULDCATEGORIZEGROCERYITEMS") ?? 0) != 0
}

/// Port of parse_list_color (ZCOLOR NSKeyedArchiver binary plist -> {name, hex}).
/// Default fallback is {"blue","#007AFF"}. NOTE: resolving the NSKeyedArchiver UID chain via
/// PropertyListSerialization is best-effort; on any failure we return the default. Live custom
/// list colors may therefore fall back to default in JSON until a proper NSKeyedUnarchiver pass
/// is added (follow-up). The parity oracle only exercises the default path.
public func parseListColor(_ blob: Data?) -> (name: String, hex: String) {
    let fallback = (name: "blue", hex: "#007AFF")
    guard let blob, !blob.isEmpty else { return fallback }
    guard let plist = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
          let dict = plist as? [String: Any],
          let objects = dict["$objects"] as? [Any] else { return fallback }
    func resolve(_ uid: Any?) -> String? {
        guard let uid else { return nil }
        if let n = (uid as? NSNumber)?.intValue, n >= 0, n < objects.count { return objects[n] as? String }
        return nil
    }
    for obj in objects {
        guard let o = obj as? [String: Any], o["ckSymbolicColorName"] != nil else { continue }
        let name = resolve(o["ckSymbolicColorName"]) ?? "blue"
        let hex = resolve(o["daHexString"]) ?? ""
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

/// Port of list_to_dict — ordered keys: id, title, listType, isGroceries, [objectUUID], [color],
/// [badge, badgeEmblem], [grocery], [pinned], [pinnedDate].
public func listToDict(_ row: ReminderRow) -> [(String, JSONValue)] {
    let isGroceries = isGroceryListRow(row)
    var item: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("title", row.string("ZNAME").map { .string($0) } ?? .null),
        ("listType", .string(isGroceries ? "groceries" : "standard")),
        ("isGroceries", .bool(isGroceries)),
    ]
    if let uuid = row.string("ZCKIDENTIFIER"), !uuid.isEmpty { item.append(("objectUUID", .string(uuid))) }
    if row.has("ZCOLOR"), let blob = row.data("ZCOLOR"), !blob.isEmpty {
        let c = parseListColor(blob)
        item.append(("color", .object([("name", .string(c.name)), ("hex", .string(c.hex))])))
    }
    if row.has("ZBADGEEMBLEM"), let raw = row.string("ZBADGEEMBLEM"), !raw.isEmpty {
        if let badge = parseBadgeEmblem(raw) { item.append(("badge", .object(badge))) }
        item.append(("badgeEmblem", .string(raw)))
    }
    if let grocery = groceryListPayload(row), isGroceries || groceryHasAnyTruthy(grocery) {
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
