import Foundation

/// Port of uuid_from_blob: 16-byte blob -> uppercase UUID string, else nil.
public func uuidFromBlob(_ value: Data?) -> String? {
    guard let value, value.count == 16 else { return nil }
    let u = value.withUnsafeBytes { raw in
        NSUUID(uuidBytes: raw.bindMemory(to: UInt8.self).baseAddress!)
    }
    return u.uuidString.uppercased()
}

/// Port of template_deep_link.
public func templateDeepLink(_ objectUUID: String?) -> String? {
    guard let objectUUID, !objectUUID.isEmpty else { return nil }
    return Constants.deepLinkTemplatePrefix + objectUUID
}

/// Port of template_public_link: icloud URL with a fragment = quote(name.replace(" ","_"), safe=":_").
public func templatePublicLink(templateName: String?, publicUUID: String?) -> String? {
    guard let publicUUID, !publicUUID.isEmpty else { return nil }
    let underscored = (templateName ?? "").replacingOccurrences(of: " ", with: "_")
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "_.-~:")   // urllib always-safe (_.-~) + safe=":_"
    let fragment = underscored.addingPercentEncoding(withAllowedCharacters: allowed) ?? underscored
    return "https://www.icloud.com/reminders/template/\(publicUUID)#\(fragment)"
}

/// Port of decode_template_metadata: strip a leading 0x01, json-decode to an object (order-preserving).
public func decodeTemplateMetadata(_ blob: Data?) -> [(String, JSONValue)]? {
    guard let blob, !blob.isEmpty else { return nil }
    var data = blob
    if data.first == 0x01 { data = data.dropFirst() }
    guard case let .object(pairs)? = OrderedJSON.parse(data) else { return nil }
    return pairs
}

private func metaValue(_ meta: [(String, JSONValue)], _ key: String) -> JSONValue? {
    for (k, v) in meta where k == key { return v }
    return nil
}

/// Port of _metadata_tags.
private func metadataTags(_ meta: [(String, JSONValue)]) -> [String] {
    guard case let .array(items)? = metaValue(meta, "hashtags") else { return [] }
    var tags: [String] = []
    for item in items {
        if case let .object(pairs) = item {
            for (k, v) in pairs where k == "name" { if case let .string(s) = v, !s.isEmpty { tags.append(s) } }
        } else if case let .string(s) = item { tags.append(s) }
    }
    return tags
}

/// Apple-seconds -> ISO local string, or nil for falsey (mirrors _template_time).
func templateTime(_ row: ReminderRow, _ key: String) -> String? {
    guard let v = row.double(key), v != 0 else { return nil }
    return AppleEpoch.ts(v)
}

/// Port of saved_reminder_to_dict.
public func savedReminderToDict(_ row: ReminderRow) -> [(String, JSONValue)] {
    let meta = decodeTemplateMetadata(row.data("ZMETADATA")) ?? []
    let metaTitle: String? = { if case let .string(s)? = metaValue(meta, "title") { return s }; return nil }()
    let title = row.string("ZTITLE").flatMap { $0.isEmpty ? nil : $0 } ?? metaTitle ?? ""
    // priority: ZPRIORITY column if present, else metadata.priority; then `or 0`.
    var priVal = 0
    if row.has("ZPRIORITY") { priVal = row.int("ZPRIORITY") ?? 0 }
    else if case let .int(p)? = metaValue(meta, "priority") { priVal = p }
    var payload: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("title", .string(title)),
        ("objectUUID", row.string("ZCKIDENTIFIER").map { .string($0) } ?? .null),
        ("priority", .string(Constants.priorityName[priVal] ?? "none")),
    ]
    if let created = templateTime(row, "ZCREATIONDATE") { payload.append(("createdDate", .string(created))) }
    if let disp = templateTime(row, "ZDISPLAYDATEDATE") {
        payload.append(("displayDate", .string(disp)))
        payload.append(("displayDateIsAllDay", .bool((row.int("ZDISPLAYDATEISALLDAY") ?? 0) != 0)))
    }
    if let parentUUID = uuidFromBlob(row.data("ZPARENTSAVEDREMINDERIDENTIFIER")) {
        payload.append(("parentObjectUUID", .string(parentUUID)))
    }
    if !meta.isEmpty {
        payload.append(("metadataKeys", .array(meta.map { $0.0 }.sorted().map { .string($0) })))
        // Python bool(metadata.get("flagged", False)) — accept bool/int/double/string truthiness.
        let flagged: Bool = {
            switch metaValue(meta, "flagged") {
            case .bool(let b)?: return b
            case .int(let i)?: return i != 0
            case .double(let d)?: return d != 0
            case .string(let s)?: return !s.isEmpty
            default: return false
            }
        }()
        payload.append(("flagged", .bool(flagged)))
        let tags = metadataTags(meta)
        if !tags.isEmpty { payload.append(("tags", .array(tags.map { .string($0) }))) }
        for (mk, ok) in [("dueDateComponents", "dueDateComponents"), ("startDateComponents", "startDateComponents"),
                         ("recurrenceRules", "recurrenceRules"), ("alarmTriggers", "alarmTriggers")] {
            if let v = metaValue(meta, mk), !isEmptyJSON(v) { payload.append((ok, v)) }
        }
        if let nd = metaValue(meta, "notesDocumentData"), !isEmptyJSON(nd) { payload.append(("hasNotes", .bool(true))) }
    }
    return payload
}

/// Port of template_section_to_dict.
public func templateSectionToDict(_ row: ReminderRow) -> [(String, JSONValue)] {
    let name = row.string("ZDISPLAYNAME").flatMap { $0.isEmpty ? nil : $0 }
        ?? row.string("ZCANONICALNAME").flatMap { $0.isEmpty ? nil : $0 } ?? ""
    var payload: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("name", .string(name)),
        ("objectUUID", row.string("ZCKIDENTIFIER").map { .string($0) } ?? .null),
    ]
    if let created = templateTime(row, "ZCREATIONDATE") { payload.append(("createdDate", .string(created))) }
    if let canonical = row.string("ZCANONICALNAME"), !canonical.isEmpty, canonical != name {
        payload.append(("canonicalName", .string(canonical)))
    }
    return payload
}

/// Port of template_to_dict (optionally with sections + items).
public func templateToDict(_ row: ReminderRow, store: RemindersStore? = nil, includeItems: Bool = false) -> [(String, JSONValue)] {
    let objectUUID = row.string("ZCKIDENTIFIER")
    var payload: [(String, JSONValue)] = [
        ("id", .int(row.int("Z_PK") ?? 0)),
        ("name", row.string("ZNAME").map { .string($0) } ?? .null),
        ("objectUUID", objectUUID.map { .string($0) } ?? .null),
        ("deepLink", templateDeepLink(objectUUID).map { .string($0) } ?? .null),
        ("itemCount", .int(row.int("item_count") ?? 0)),
        ("sectionCount", .int(row.int("section_count") ?? 0)),
    ]
    if let c = templateTime(row, "ZCREATIONDATE") { payload.append(("createdDate", .string(c))) }
    if let m = templateTime(row, "ZLASTMODIFIEDDATE") { payload.append(("modifiedDate", .string(m))) }
    if row.has("ZBADGEEMBLEM"), let badge = row.string("ZBADGEEMBLEM"), !badge.isEmpty {
        payload.append(("badgeEmblem", .string(badge)))
    }
    if let publicUUID = uuidFromBlob(row.data("ZPUBLICLINKURLUUID")) {
        var pub: [(String, JSONValue)] = [
            ("uuid", .string(publicUUID)),
            ("url", templatePublicLink(templateName: row.string("ZNAME"), publicUUID: publicUUID).map { .string($0) } ?? .null),
        ]
        if let c = templateTime(row, "ZPUBLICLINKCREATIONDATE") { pub.append(("createdDate", .string(c))) }
        if let m = templateTime(row, "ZPUBLICLINKLASTMODIFIEDDATE") { pub.append(("modifiedDate", .string(m))) }
        if let e = templateTime(row, "ZPUBLICLINKEXPIRATIONDATE") { pub.append(("expirationDate", .string(e))) }
        if let cfg = row.data("ZPUBLICLINKCONFIGURATIONDATA"), !cfg.isEmpty {
            pub.append(("configurationLength", .int(cfg.count)))
        }
        payload.append(("publicLink", .object(pub)))
    }
    if includeItems, let store {
        let pk = row.int("Z_PK") ?? 0
        payload.append(("sections", .array(store.templateSections(pk).map { .object(templateSectionToDict($0)) })))
        payload.append(("items", .array(store.templateSavedReminders(pk).map { .object(savedReminderToDict($0)) })))
    }
    return payload
}
