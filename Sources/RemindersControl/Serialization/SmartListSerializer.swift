import Foundation

/// Port of smart_list_display_name.
public func smartListDisplayName(_ row: ReminderRow) -> String {
    if let name = row.string("ZNAME"), !name.isEmpty { return name }
    let smartType = row.string("ZSMARTLISTTYPE") ?? ""
    if let mapped = Constants.smartListTypeNames[smartType] { return mapped }
    let last = smartType.split(separator: ".").last.map(String.init) ?? ""
    return last.isEmpty ? "(unnamed)" : last
}

/// Port of smart_list_to_dict (ordered keys).
public func smartListToDict(_ row: ReminderRow) -> [(String, JSONValue)] {
    let filterData = row.data("ZFILTERDATA") ?? row.string("ZFILTERDATA").map { Data($0.utf8) }
    let decoded = decodeSmartListFilterBlob(filterData)
    let pinnedDate = row.double("ZPINNEDDATE")
    let smartType = row.string("ZSMARTLISTTYPE")
    var payload: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("objectUUID", row.string("ZCKIDENTIFIER").map { .string($0) } ?? .null),
        ("name", .string(smartListDisplayName(row))),
        ("kind", .string(smartType == Constants.customSmartListType ? "custom" : "built-in")),
        ("smartListType", smartType.map { .string($0) } ?? .null),
        ("filterLength", .int(filterData?.count ?? 0)),
    ]
    if row.has("ZCOLOR"), let blob = row.data("ZCOLOR"), !blob.isEmpty {
        let c = parseListColor(blob)
        payload.append(("color", .object([("name", .string(c.name)), ("hex", .string(c.hex))])))
    }
    if row.has("ZBADGEEMBLEM"), let raw = row.string("ZBADGEEMBLEM"), !raw.isEmpty {
        if let badge = parseBadgeEmblem(raw) { payload.append(("badge", .object(badge))) }
        payload.append(("badgeEmblem", .string(raw)))
    }
    if let minV = row.int("ZMINIMUMSUPPORTEDAPPVERSION") { payload.append(("minimumSupportedVersion", .int(minV))) }
    if let effV = row.int("ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION") { payload.append(("effectiveMinimumSupportedVersion", .int(effV))) }
    if row.has("ZISPINNEDBYCURRENTUSER") || pinnedDate != nil {
        var isPinned = (row.int("ZISPINNEDBYCURRENTUSER") ?? 0) != 0
        if !isPinned, let pd = pinnedDate { isPinned = pd > 0 }
        payload.append(("pinned", .bool(isPinned)))
    }
    if let pd = pinnedDate { payload.append(("pinnedDate", .double(pd))) }
    if let summary = decoded.summary { payload.append(("filter", .object(summary))) }
    if let enc = decoded.encoding {
        payload.append(("filterEncoding", .string(enc)))
        payload.append(("filterJSON", decoded.payload ?? .null))
    } else if let err = decoded.error {
        payload.append(("filterError", .string(err)))
    }
    return payload
}
