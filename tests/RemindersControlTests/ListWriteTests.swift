import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// W11: list-create / list-rename / list-delete (EventKit list ops; P10 appearance flags live).
@Suite struct ListWriteTests {
    /// Fixture store with two lists: pk 10 'Work', pk 11 'Groceries'.
    private func store() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'Work',0)")
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (11,3,'Groceries',0)")
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    // MARK: - list-create (public path — named color or no color, EventKit writer)

    @Test func createBasic() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        let human = try await ListCreate.perform(name: "Projects", json: false, writer: m, priv: priv)
        #expect(m.calls == [.createList(title: "Projects", color: nil)])
        #expect(priv.calls.isEmpty)
        #expect(human == WriteOutcome.ok("Created list: Projects\n"))

        let m2 = MockWriter()
        let priv2 = MockPrivateWriter()
        let js = try await ListCreate.perform(name: "Projects", json: true, writer: m2, priv: priv2)
        #expect(js.stdout == #"{"status": "created", "name": "Projects"}"# + "\n")
        #expect(m2.calls == [.createList(title: "Projects", color: nil)])
        #expect(priv2.calls.isEmpty)
    }

    @Test func createWithColor() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        let out = try await ListCreate.perform(name: "Projects", color: "red", json: false, writer: m, priv: priv)
        #expect(m.calls == [.createList(title: "Projects", color: "red")])
        #expect(priv.calls.isEmpty)
        #expect(out.exitCode == 0)
    }

    @Test func createTealAccepted() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        let out = try await ListCreate.perform(name: "Projects", color: "teal", json: false, writer: m, priv: priv)
        #expect(m.calls == [.createList(title: "Projects", color: "teal")])
        #expect(priv.calls.isEmpty)
        #expect(out.exitCode == 0)
    }

    /// Named color → stays on public EventKit path (writer called, priv NOT called).
    @Test func createNamedColorStaysPublic() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        let out = try await ListCreate.perform(name: "Projects", color: "red", json: false, writer: m, priv: priv)
        #expect(m.calls == [.createList(title: "Projects", color: "red")])
        #expect(priv.calls.isEmpty)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created list: Projects\n")
    }

    /// Bad color → hex-allowed validation message (P5 path, not old 9-name message).
    @Test func createBadColor() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await ListCreate.perform(name: "Projects", color: "mauve", json: false, writer: m, priv: priv)
        }
        #expect(out.stderr == "Error: unsupported list color 'mauve'. Use red, orange, yellow, green, blue, purple, brown, gray, cyan, or #RRGGBB.\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
        #expect(priv.calls.isEmpty)
    }

    @Test func createWriterFailureWrapped() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        m.throwError = WriteError("boom")
        let out = await WriteDispatch.perform {
            try await ListCreate.perform(name: "Projects", json: false, writer: m, priv: priv)
        }
        #expect(out.stderr == "Error: Failed to create list 'Projects': boom\n")
        #expect(out.exitCode == 1)
    }

    // MARK: - list-create (private path — hex color / symbol / emoji / groceries)

    /// --symbol → private path; writer NOT called; human output has metadata line.
    @Test func createSymbolPrivate() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        priv.result = PrivateResult(status: "created", fields: ["id": .string("UUID-1"), "url": .string("x-apple-reminderkit://REMCDList/UUID-1")])
        let out = try await ListCreate.perform(name: "Projects", symbol: "education3", json: false, writer: m, priv: priv)
        #expect(m.calls.isEmpty)
        #expect(priv.calls.count == 1)
        if case .createList(let name, let appearance) = priv.calls[0] {
            #expect(name == "Projects")
            #expect(appearance.symbol == "education3")
        } else {
            Issue.record("Expected createList call, got \(priv.calls[0])")
        }
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created list: Projects\nApplied private metadata: symbol=education3\n")
    }

    /// --symbol → JSON output has "private" sub-object (WITH default spacing).
    @Test func createSymbolPrivateJSON() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        priv.result = PrivateResult(status: "created", fields: ["id": .string("UUID-1")])
        let out = try await ListCreate.perform(name: "Projects", symbol: "education3", json: true, writer: m, priv: priv)
        #expect(m.calls.isEmpty)
        #expect(out.exitCode == 0)
        let data = Data(out.stdout.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["status"] as? String == "created")
        #expect(obj["name"] as? String == "Projects")
        let privObj = try #require(obj["private"] as? [String: Any])
        #expect(privObj["status"] as? String == "created")
        #expect(privObj["id"] as? String == "UUID-1")
        // Verify the JSON uses default spacing (WITH spaces after colon/comma)
        #expect(out.stdout.contains(": "))
    }

    /// Hex color → private path; appearance.color uppercased; details "color=#AABBCC".
    @Test func createHexColorPrivate() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        priv.result = PrivateResult(status: "created")
        let out = try await ListCreate.perform(name: "Projects", color: "#aabbcc", json: false, writer: m, priv: priv)
        #expect(m.calls.isEmpty)
        #expect(priv.calls.count == 1)
        if case .createList(_, let appearance) = priv.calls[0] {
            #expect(appearance.color == "#AABBCC")
        } else {
            Issue.record("Expected createList call")
        }
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created list: Projects\nApplied private metadata: color=#AABBCC\n")
    }

    /// --groceries --grocery-locale → private path; details "groceries locale=en_US".
    @Test func createGroceriesPrivate() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        priv.result = PrivateResult(status: "created")
        let out = try await ListCreate.perform(name: "Projects", groceries: true, groceryLocale: "en-US", json: false, writer: m, priv: priv)
        #expect(m.calls.isEmpty)
        #expect(priv.calls.count == 1)
        if case .createList(_, let appearance) = priv.calls[0] {
            #expect(appearance.shouldCategorizeGroceryItems == true)
            #expect(appearance.groceryLocaleID == "en_US")
        } else {
            Issue.record("Expected createList call")
        }
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created list: Projects\nApplied private metadata: groceries locale=en_US\n")
    }

    /// Private path failure → wrapped error message.
    @Test func createPrivateFailureWrapped() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        priv.result = PrivateResult(status: "error", message: "boom")
        let out = await WriteDispatch.perform {
            try await ListCreate.perform(name: "Projects", symbol: "education3", json: false, writer: m, priv: priv)
        }
        #expect(out.stderr == "Error: Failed to create list 'Projects': boom\n")
        #expect(out.exitCode == 1)
    }

    /// --color red --symbol → details order: color first, then symbol.
    @Test func createColorAndSymbolDetails() async throws {
        let m = MockWriter()
        let priv = MockPrivateWriter()
        priv.result = PrivateResult(status: "created")
        let out = try await ListCreate.perform(name: "Projects", color: "red", symbol: "education3", json: false, writer: m, priv: priv)
        #expect(m.calls.isEmpty)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created list: Projects\nApplied private metadata: color=red, symbol=education3\n")
    }

    // MARK: - list-rename

    @Test func renameBasic() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let human = try await ListRename.perform(name: "Work", newNamePositional: "Renamed", listId: nil, newNameOption: nil, json: false, store: s, writer: m)
        #expect(m.calls == [.renameList(currentTitle: "Work", newTitle: "Renamed")])
        #expect(human == WriteOutcome.ok("Renamed: Work -> Renamed\n"))

        let m2 = MockWriter()
        let js = try await ListRename.perform(name: "Work", newNamePositional: "Renamed", listId: nil, newNameOption: nil, json: true, store: s, writer: m2)
        #expect(js.stdout == #"{"status": "renamed", "id": 10, "old_name": "Work", "new_name": "Renamed"}"# + "\n")
    }

    @Test func renameByListId() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let js = try await ListRename.perform(name: nil, newNamePositional: nil, listId: 10, newNameOption: "Renamed", json: true, store: s, writer: m)
        // old_name is the RESOLVED title 'Work', not the raw arg.
        #expect(m.calls == [.renameList(currentTitle: "Work", newTitle: "Renamed")])
        #expect(js.stdout == #"{"status": "renamed", "id": 10, "old_name": "Work", "new_name": "Renamed"}"# + "\n")
    }

    @Test func renameBothNewNames() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await ListRename.perform(name: "Work", newNamePositional: "Foo", listId: nil, newNameOption: "Bar", json: false, store: s, writer: m) }
        #expect(out.stderr == "Error: pass the new list name as an argument or --new-name, not both.\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    @Test func renameMissingNewName() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await ListRename.perform(name: "Work", newNamePositional: nil, listId: nil, newNameOption: nil, json: false, store: s, writer: m) }
        #expect(out.stderr == "Error: pass a new list name.\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    @Test func renameFailureWrapped() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.throwError = WriteError("nope")
        let out = await WriteDispatch.perform { try await ListRename.perform(name: "Work", newNamePositional: "Renamed", listId: nil, newNameOption: nil, json: false, store: s, writer: m) }
        #expect(out.stderr == "Error: Failed to rename list 'Work': nope\n")
        #expect(out.exitCode == 1)
    }

    // MARK: - list-delete

    @Test func deleteForce() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let human = try await ListDelete.perform(name: "Work", listId: nil, force: true, json: false, store: s, writer: m, confirm: { _ in Issue.record("should not prompt with --force"); return false })
        #expect(m.calls == [.deleteList(title: "Work")])
        #expect(human == WriteOutcome.ok("Deleted list: Work\n"))

        let m2 = MockWriter()
        let js = try await ListDelete.perform(name: "Work", listId: nil, force: true, json: true, store: s, writer: m2, confirm: { _ in false })
        #expect(js.stdout == #"{"status": "deleted", "id": 10, "name": "Work"}"# + "\n")
    }

    @Test func deleteConfirmYes() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); var seenPrompt = ""
        let out = try await ListDelete.perform(name: "Work", listId: nil, force: false, json: false, store: s, writer: m, confirm: { p in seenPrompt = p; return true })
        #expect(seenPrompt == "Delete list 'Work'? This cannot be undone. [y/N] ")
        #expect(m.calls == [.deleteList(title: "Work")])
        #expect(out.stdout == "Deleted list: Work\n")
    }

    @Test func deleteConfirmNo() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        // --json mode: the prompt still fires and Cancelled. is plain text (no JSON), exit 0.
        let out = try await ListDelete.perform(name: "Work", listId: nil, force: false, json: true, store: s, writer: m, confirm: { _ in false })
        #expect(out == WriteOutcome.ok("Cancelled.\n"))
        #expect(m.calls.isEmpty)
    }

    @Test func deleteFailureWrapped() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        m.throwError = WriteError("kaboom")
        let out = await WriteDispatch.perform { try await ListDelete.perform(name: "Work", listId: nil, force: true, json: false, store: s, writer: m, confirm: { _ in true }) }
        #expect(out.stderr == "Error: Failed to delete list 'Work': kaboom\n")
        #expect(out.exitCode == 1)
    }
}
