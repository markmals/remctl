import Foundation
import ReminderKitPrivate

/// Production `PrivateWriter` backed by the in-process `RKPDispatch` entrypoint
/// (ObjC target `ReminderKitPrivate`). Each method marshals a typed Swift call
/// into the request dict that `RKPDispatch` expects, dispatches it, and unmarshals
/// the `NSDictionary` response into a `PrivateResult`.
///
/// NOTE: This class performs live ReminderKit saves against the real Reminders
/// store. It is NOT exercised in CI — that requires a running Reminders daemon
/// and a granted Reminders TCC permission. Manual end-to-end verification is
/// deferred to Task P18. Only the pure static helpers (`isTransient`,
/// `anyToJSONValue`) are covered by `ReminderKitWriterTests`.
public final class ReminderKitWriter: PrivateWriter {

    public init() {}

    // MARK: - Idempotent-retry set

    /// Actions that are safe to retry on a transient error (matching Python's
    /// `IDEMPOTENT_PRIVATE_ACTIONS`).
    private static let idempotentActions: Set<String> = [
        "set_flagged",
        "assign_section",
        "assign_sharee",
        "clear_assignment",
        "set_urgent",
        "set_early_reminder",
    ]

    // MARK: - Transient-error detection

    /// Returns `true` when the error message indicates a transient ReminderKit
    /// helper-communication failure. Mirrors Python `private_helper_error_is_transient`.
    public static func isTransient(message: String?) -> Bool {
        guard let msg = message else { return false }
        // ReminderKit’s transient XPC error reads "Couldn’t communicate with a helper application."
        // The matched substring is apostrophe-free, so it matches both the curly-U+2019 and straight forms.
        return msg.contains("communicate with a helper application")
    }

    // MARK: - Response unmarshalling

    /// Converts an `Any` value from an `NSDictionary` response into a `JSONValue`.
    ///
    /// - `NSString`            → `.string`
    /// - `NSNumber` (bool)     → `.bool`   (CFBoolean singleton identity)
    /// - `NSNumber` (integer)  → `.int`
    /// - `NSNumber` (floating) → `.double`
    /// - `NSArray`             → `.array`
    /// - `NSDictionary`        → `.object` (key order reflects NSDictionary's natural
    ///                           enumeration — not insertion-ordered, but this only
    ///                           affects the echoed `fields`, not any parity-critical
    ///                           request bytes)
    /// - `NSNull` / `nil`      → `.null`
    static func anyToJSONValue(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }

        if let num = any as? NSNumber {
            // @YES/@NO (ObjC) and NSNumber(value: Bool) (Swift) are the CFBoolean singletons —
            // identity is the only reliable bool discriminator on macOS (objCType is "c", not "B").
            if num === (kCFBooleanTrue as AnyObject) || num === (kCFBooleanFalse as AnyObject) {
                return .bool(num.boolValue)
            }
            // Differentiate integer vs floating-point encodings.
            let typeChar = String(cString: num.objCType)
            let floatTypes: Set<String> = ["f", "d"]
            if floatTypes.contains(typeChar) {
                return .double(num.doubleValue)
            }
            return .int(num.intValue)
        }

        if let str = any as? NSString {
            return .string(str as String)
        }

        if let arr = any as? NSArray {
            return .array(arr.compactMap { anyToJSONValue($0) })
        }

        if let dict = any as? NSDictionary {
            var pairs: [(String, JSONValue)] = []
            for key in dict.allKeys {
                guard let k = key as? String else { continue }
                pairs.append((k, anyToJSONValue(dict[key]!)))
            }
            return .object(pairs)
        }

        // Fallback — should not happen for well-formed RKPDispatch responses.
        return .null
    }

    // MARK: - Dispatch + unmarshal

    private func dispatch(_ request: [String: Any]) -> PrivateResult {
        // RKPDispatch returns NSDictionary bridged as [AnyHashable: Any]; cast back
        // to NSDictionary so we can use allKeys / object(forKey:).
        let raw = RKPDispatch(request as [AnyHashable: Any]) as NSDictionary
        let status = (raw["status"] as? String) ?? "error"
        let message = raw["message"] as? String
        var fields: [String: JSONValue] = [:]
        for key in raw.allKeys {
            guard let k = key as? String, k != "status", k != "message" else { continue }
            if let value = raw.object(forKey: k) {
                fields[k] = ReminderKitWriter.anyToJSONValue(value)
            }
        }
        return PrivateResult(status: status, fields: fields, message: message)
    }

    /// Dispatches `request`, retrying up to 3 times (total) for idempotent actions
    /// when a transient ReminderKit error is detected. Non-idempotent actions are
    /// attempted exactly once. A final transient failure gets the remindd hint
    /// appended when the daemon is verifiably not running (upstream aba7cf5).
    private func dispatchWithRetry(_ request: [String: Any]) async -> PrivateResult {
        let action = request["action"] as? String ?? ""
        let maxAttempts = ReminderKitWriter.idempotentActions.contains(action) ? 3 : 1

        var result = dispatch(request)
        var attempt = 1
        while attempt < maxAttempts {
            if result.status != "error" { break }
            guard ReminderKitWriter.isTransient(message: result.message) else { break }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            result = dispatch(request)
            attempt += 1
        }
        if result.status == "error", ReminderKitWriter.isTransient(message: result.message) {
            let enriched = ReminderKitWriter.enrichTransientMessage(
                result.message, remindd: ReminderKitWriter.reminddRunning())
            return PrivateResult(status: result.status, fields: result.fields, message: enriched)
        }
        return result
    }

    /// Port of `remindd_running` (upstream aba7cf5): pgrep -x remindd; nil when the
    /// probe itself fails or times out (then no hint is added).
    static func reminddRunning() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "remindd"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        return p.terminationStatus == 0
    }

    /// Append the "open Reminders.app" guidance to a TRANSIENT error message when
    /// remindd is verifiably stopped. Non-transient messages and unknown daemon
    /// state pass through unchanged.
    static func enrichTransientMessage(_ message: String?, remindd: Bool?) -> String? {
        guard let message, isTransient(message: message), remindd == false else { return message }
        return message + " Reminders daemon (remindd) is not running; open Reminders.app, then retry."
    }

    // MARK: - Appearance helper

    /// Builds the appearance key subset for list/smart-list create and update actions.
    /// Only non-nil fields are included, matching the Python `list_private_appearance_payload`
    /// behaviour.
    private func appearanceKeys(_ appearance: ListAppearance) -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = appearance.name   { d["name"]   = v }
        if let v = appearance.color  { d["color"]  = v }
        if let v = appearance.symbol { d["symbol"] = v }
        if let v = appearance.emoji  { d["emoji"]  = v }
        if let v = appearance.shouldCategorizeGroceryItems { d["shouldCategorizeGroceryItems"] = v }
        if let v = appearance.groceryLocaleID { d["groceryLocaleID"] = v }
        return d
    }

    // MARK: - SubtaskSpec → dict

    private func subtaskSpecDict(_ spec: SubtaskSpec) -> [String: Any] {
        var d: [String: Any] = ["title": spec.title]
        if let v = spec.notes    { d["notes"]    = v }
        if let v = spec.due      { d["due"]      = v }
        if let v = spec.priority { d["priority"] = v }
        if let v = spec.alarm    { d["alarm"]    = v }
        if let v = spec.recurrence    { d["recurrence"]    = v }
        if let v = spec.earlyReminder { d["earlyReminder"] = v }
        if !spec.urls.isEmpty   { d["urls"]   = spec.urls }
        if !spec.tags.isEmpty   { d["tags"]   = spec.tags }
        if !spec.images.isEmpty { d["images"] = spec.images }
        if let v = spec.flagged  { d["flagged"]  = v }
        if let v = spec.urgent   { d["urgent"]   = v }
        if let v = spec.latitude      { d["latitude"]      = v }
        if let v = spec.longitude     { d["longitude"]     = v }
        if let v = spec.locationTitle { d["locationTitle"] = v }
        if let v = spec.radius    { d["radius"]    = v }
        if let v = spec.proximity { d["proximity"] = v }
        return d
    }

    // MARK: - PrivateWriter — reminder-scoped

    public func setFlagged(id: String, flagged: Bool) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "set_flagged", "id": id, "flagged": flagged]
        return await dispatchWithRetry(req)
    }

    public func addPrivateMetadata(id: String, urls: [String], tags: [String]) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "add_private_metadata", "id": id, "urls": urls, "tags": tags]
        return await dispatchWithRetry(req)
    }

    public func assignSection(id: String, sectionId: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "assign_section", "id": id, "sectionId": sectionId]
        return await dispatchWithRetry(req)
    }

    public func addSectionAndAssign(id: String, name: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "add_section_and_assign", "id": id, "name": name]
        return await dispatchWithRetry(req)
    }

    public func assignSharee(id: String, assigneeId: String, originatorId: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "assign_sharee", "id": id, "assigneeId": assigneeId, "originatorId": originatorId]
        return await dispatchWithRetry(req)
    }

    public func clearAssignment(id: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "clear_assignment", "id": id]
        return await dispatchWithRetry(req)
    }

    public func addSubtasks(id: String, subtasks: [SubtaskSpec]) async throws -> PrivateResult {
        let subtaskDicts = subtasks.map { subtaskSpecDict($0) }
        let req: [String: Any] = ["action": "add_subtasks", "id": id, "subtasks": subtaskDicts]
        return await dispatchWithRetry(req)
    }

    public func addAttachments(id: String, images: [String]) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "add_attachments", "id": id, "files": [String](), "images": images]
        return await dispatchWithRetry(req)
    }

    public func setUrgent(id: String, urgent: Bool) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "set_urgent", "id": id, "urgent": urgent]
        return await dispatchWithRetry(req)
    }

    public func setEarlyReminder(id: String, spec: EarlyReminderWrite) async throws -> PrivateResult {
        var req: [String: Any] = ["action": "set_early_reminder", "id": id]
        switch spec {
        case .clear(let existingIdentifiers):
            req["clear"] = true
            if !existingIdentifiers.isEmpty {
                req["existingIdentifiers"] = existingIdentifiers
            }
        case .set(let unit, let count, let existingIdentifiers):
            req["unit"] = unit
            req["count"] = count
            if !existingIdentifiers.isEmpty {
                req["existingIdentifiers"] = existingIdentifiers
            }
        }
        return await dispatchWithRetry(req)
    }

    public func addLocationAlarm(id: String, location: PrivateLocation) async throws -> PrivateResult {
        var req: [String: Any] = [
            "action":    "add_location_alarm",
            "id":        id,
            "title":     location.title,
            "latitude":  location.latitude,
            "longitude": location.longitude,
            "radius":    location.radius,
            "proximity": location.proximity,
        ]
        if let addr = location.address {
            req["address"] = addr
        }
        return await dispatchWithRetry(req)
    }

    public func categorizeGroceryItems(listId: String, reminderIds: [String]) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "categorize_grocery_items", "listId": listId, "reminderIds": reminderIds]
        return await dispatchWithRetry(req)
    }

    // MARK: - PrivateWriter — list / smart-list / template

    public func setListAppearance(listId: String, appearance: ListAppearance) async throws -> PrivateResult {
        var req: [String: Any] = ["action": "set_list_appearance", "listId": listId]
        for (k, v) in appearanceKeys(appearance) { req[k] = v }
        return await dispatchWithRetry(req)
    }

    public func setListPinned(listId: String, pinned: Bool) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "set_list_pinned", "listId": listId, "pinned": pinned]
        return await dispatchWithRetry(req)
    }

    public func setSmartListPinned(smartListId: String, pinned: Bool) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "set_smart_list_pinned", "smartListId": smartListId, "pinned": pinned]
        return await dispatchWithRetry(req)
    }

    public func createList(name: String, appearance: ListAppearance) async throws -> PrivateResult {
        var req: [String: Any] = ["action": "create_list", "name": name]
        for (k, v) in appearanceKeys(appearance) { req[k] = v }
        return await dispatchWithRetry(req)
    }

    public func createSmartList(name: String, filterData: Data, appearance: ListAppearance) async throws -> PrivateResult {
        var req: [String: Any] = [
            "action":     "create_smart_list",
            "name":       name,
            "filterData": filterData.base64EncodedString(),
        ]
        for (k, v) in appearanceKeys(appearance) { req[k] = v }
        return await dispatchWithRetry(req)
    }

    public func updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance) async throws -> PrivateResult {
        var req: [String: Any] = ["action": "update_smart_list", "smartListId": smartListId]
        if let fd = filterData {
            req["filterData"] = fd.base64EncodedString()
        }
        for (k, v) in appearanceKeys(appearance) { req[k] = v }
        return await dispatchWithRetry(req)
    }

    public func deleteSmartList(smartListId: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "delete_smart_list", "smartListId": smartListId]
        return await dispatchWithRetry(req)
    }

    public func createTemplate(name: String, sourceListId: String, includeCompleted: Bool) async throws -> PrivateResult {
        // NOTE: the ObjC handler reads "listId" (not "sourceListId") for the source list.
        let req: [String: Any] = [
            "action":          "create_template",
            "name":            name,
            "listId":          sourceListId,
            "includeCompleted": includeCompleted,
        ]
        return await dispatchWithRetry(req)
    }

    public func applyTemplate(templateId: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "apply_template", "templateId": templateId]
        return await dispatchWithRetry(req)
    }

    public func deleteTemplate(templateId: String) async throws -> PrivateResult {
        let req: [String: Any] = ["action": "delete_template", "templateId": templateId]
        return await dispatchWithRetry(req)
    }
}
