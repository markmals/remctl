import Foundation
import GRDB

extension ListCreate {
    /// `list-create --group/--group-id` (upstream e013fb9): the list is created through ReminderKit,
    /// then moved into the group. The group is resolved before anything is written, and both the
    /// new list and its membership are read back from the store before they are reported.
    static func performInGroup(
        name: String, group: String?, groupId: Int?, color: String?, symbol: String?, emoji: String?,
        groceries: Bool, groceryLocale: String?, json: Bool,
        store: RemindersStore, private priv: PrivateWriter, readback: Readback = .standard
    ) async throws -> WriteOutcome {
        try validateListAppearanceArgs(color: color, symbol: symbol, emoji: emoji,
                                       groceries: groceries, standard: false, groceryLocale: groceryLocale)
        let target = try GroupHandle(try resolveRequiredGroupTarget(store: store, name: group, groupId: groupId))
        let appearance = buildListAppearance(newName: nil, color: color, symbol: symbol, emoji: emoji,
                                             groceries: groceries, standard: false, groceryLocale: groceryLocale)
        let result = try await priv.createList(name: name, appearance: appearance).requireStatus("created")
        let list = try await waitForList(ckid: result.string("id"), name: name, store: store, readback: readback)
        let membership = try await GroupMembership.move(list, to: target, store: store, private: priv, readback: readback)

        if json {
            let payload: JSONValue = .object([
                ("status", .string("created")), ("name", .string(name)), ("id", .int(list.id)),
                ("objectUUID", .string(list.ckid)),
                ("group", .object([("id", .int(target.id)), ("title", .string(target.title)), ("objectUUID", .string(target.ckid))])),
                ("verified", .bool(true)), ("private", result.jsonObject), ("membership", membership.jsonObject),
            ])
            return .ok(payload.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        return .ok("Created list: \(safeDisplay(name))\nGroup: \(safeDisplay(target.title)) (id: \(target.id))\n"
            + appliedMetadataLine(color: color, symbol: symbol, emoji: emoji, groceries: groceries, groceryLocale: groceryLocale))
    }

    private static func waitForList(ckid: String?, name: String, store: RemindersStore,
                                    readback: Readback) async throws -> GroupMember {
        guard let ckid else {
            throw CommandFailure("list_write_unverified", "ReminderKit created the list but did not return its identifier.")
        }
        var row: Row?
        let visible = await readback.waitUntil {
            row = store.listRowByCkid(ckid)
            return row != nil
        }
        guard visible, let row else {
            throw CommandFailure("list_write_unverified",
                                 "created list \(WriteFormatting.pyRepr(name)) was not visible for group assignment.")
        }
        return try GroupMember(row)
    }
}
