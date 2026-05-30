import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// W11: list-create / list-rename / list-delete (EventKit list ops; appearance flags stubbed Phase 3).
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

    // MARK: - list-create

    @Test func createBasic() async throws {
        let m = MockWriter()
        let human = try await ListCreate.perform(name: "Projects", json: false, writer: m)
        #expect(m.calls == [.createList(title: "Projects", color: nil)])
        #expect(human == WriteOutcome.ok("Created list: Projects\n"))

        let m2 = MockWriter()
        let js = try await ListCreate.perform(name: "Projects", json: true, writer: m2)
        #expect(js.stdout == #"{"status": "created", "name": "Projects"}"# + "\n")
        #expect(m2.calls == [.createList(title: "Projects", color: nil)])
    }

    @Test func createWithColor() async throws {
        let m = MockWriter()
        let out = try await ListCreate.perform(name: "Projects", color: "red", json: false, writer: m)
        #expect(m.calls == [.createList(title: "Projects", color: "red")])
        #expect(out.exitCode == 0)
    }

    @Test func createTealAccepted() async throws {
        let m = MockWriter()
        let out = try await ListCreate.perform(name: "Projects", color: "teal", json: false, writer: m)
        #expect(m.calls == [.createList(title: "Projects", color: "teal")])
        #expect(out.exitCode == 0)
    }

    @Test func createBadColor() async throws {
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await ListCreate.perform(name: "Projects", color: "mauve", json: false, writer: m) }
        #expect(out.stderr == "Error: unsupported list color 'mauve'. Use red, orange, yellow, green, blue, purple, brown, gray, or cyan.\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    @Test func createSymbolStubbed() async throws {
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await ListCreate.perform(name: "Projects", symbol: "education3", json: false, writer: m) }
        #expect(out.stderr == "Error: --symbol requires the private metadata layer (Phase 3); not yet implemented.\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    @Test func createGroceriesStubbed() async throws {
        let m = MockWriter()
        let out = await WriteDispatch.perform { try await ListCreate.perform(name: "Projects", groceries: true, json: false, writer: m) }
        #expect(out.stderr == "Error: --groceries requires the private metadata layer (Phase 3); not yet implemented.\n")
        #expect(out.exitCode == 1)
        #expect(m.calls.isEmpty)
    }

    @Test func createWriterFailureWrapped() async throws {
        let m = MockWriter()
        m.throwError = WriteError("boom")
        let out = await WriteDispatch.perform { try await ListCreate.perform(name: "Projects", json: false, writer: m) }
        #expect(out.stderr == "Error: Failed to create list 'Projects': boom\n")
        #expect(out.exitCode == 1)
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
