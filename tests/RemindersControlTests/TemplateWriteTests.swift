import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// TemplateWriteTests – unit tests for template-create / apply / delete (P17).
//
// All tests drive the `perform` cores directly with a fixture store + MockPrivateWriter.
// Poll timing is injected (attempts:1, delay:0) so create's post-write poll never sleeps.
//
// Fixture store layout:
//   ZREMCDBASELIST:
//     - pk=10, 'Work',    ZCKIDENTIFIER='L10'  (+ 2 incomplete + 1 completed reminder)
//     - pk=11, 'NoCkid',  ZCKIDENTIFIER=NULL
//   ZREMCDTEMPLATE:
//     - pk=40, 'Daily',   ZCKIDENTIFIER='T40'
//   ZREMCDREMINDER: 3 rows on list 10 (2 incomplete, 1 completed), all account-attached.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct TemplateWriteTests {

    private func store(extraBuild: ((Database) throws -> Void)? = nil) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try FixtureDB.createTemplateSchema(db)
            // Source list 'Work' with a stable ckid.
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (10, 3, 'Work', 'L10', 0)")
            // A list with no ckid.
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZMARKEDFORDELETION) VALUES (11, 3, 'NoCkid', 0)")
            // Two incomplete + one completed reminder on list 10, all account-attached.
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION) VALUES (100, 'a', 10, 1, 0, 0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION) VALUES (101, 'b', 10, 1, 0, 0)")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION) VALUES (102, 'c', 10, 1, 1, 0)")
            // Template 'Daily' with ckid T40.
            try db.execute(sql: "INSERT INTO ZREMCDTEMPLATE (Z_PK, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (40, 'Daily', 'T40', 0)")
            try extraBuild?(db)
        }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    // MARK: - create: mutex --from-list + --from-list-id

    @Test func createMutex() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateCreate.perform(
                name: "T", fromList: "Work", fromListId: 10, includeCompleted: false,
                json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass either --from-list or --from-list-id, not both.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: required source

    @Test func createRequiredSource() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateCreate.perform(
                name: "T", fromList: nil, fromListId: nil, includeCompleted: false,
                json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: pass --from-list or --from-list-id.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: duplicate exact name

    @Test func createDuplicateName() async throws {
        let (s, dir) = try store(extraBuild: { db in
            try db.execute(sql: "INSERT INTO ZREMCDTEMPLATE (Z_PK, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (41, 'Dup', 'T41', 0)")
        }); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateCreate.perform(
                name: "Dup", fromList: "Work", fromListId: nil, includeCompleted: false,
                json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: template already exists: Dup. Use a unique template name.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: source list lacks ckid

    @Test func createNoCkid() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateCreate.perform(
                name: "T", fromList: "NoCkid", fromListId: nil, includeCompleted: false,
                json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: source list has no stable CloudKit identifier.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: source not found surfaces list resolution error

    @Test func createSourceNotFound() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateCreate.perform(
                name: "T", fromList: "Ghost", fromListId: nil, includeCompleted: false,
                json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: list not found: Ghost\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - create: happy path (no template seeded → poll finds nothing, no template key)

    @Test func createHappy() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["id": .string("NEW-T"), "url": .string("x://t")])

        let out = try await TemplateCreate.perform(
            name: "Weekly", fromList: "Work", fromListId: nil, includeCompleted: false,
            json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)

        #expect(out.exitCode == 0)
        #expect(out.stdout == "Created template: Weekly\nSource list: Work\n")
        // Source listId sent to writer is the OBJECT UUID (ZCKIDENTIFIER), not Z_PK.
        #expect(mock.calls == [.createTemplate(name: "Weekly", sourceListId: "L10", includeCompleted: false)])
    }

    // MARK: - create: includeCompleted threads through

    @Test func createIncludeCompleted() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created")

        _ = try await TemplateCreate.perform(
            name: "Weekly", fromList: "Work", fromListId: nil, includeCompleted: true,
            json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)

        #expect(mock.calls == [.createTemplate(name: "Weekly", sourceListId: "L10", includeCompleted: true)])
    }

    // MARK: - create: JSON output (indent=2), expectedItemCount present, no template (poll empty)

    @Test func createJSONIndent2() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["id": .string("NEW-T")])

        let out = try await TemplateCreate.perform(
            name: "Weekly", fromList: "Work", fromListId: nil, includeCompleted: false,
            json: true, store: s, private: mock, pollAttempts: 1, pollDelay: 0)

        // indent=2 pretty-printing: a 2-space indented line must appear.
        #expect(out.stdout.contains("\n  \"status\": \"created\""))
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["status"] as? String == "created")
        #expect(obj["name"] as? String == "Weekly")
        #expect(obj["expectedItemCount"] as? Int == 2)   // 2 incomplete reminders on list 10
        let sourceList = try #require(obj["sourceList"] as? [String: Any])
        #expect(sourceList["id"] as? Int == 10)
        #expect(sourceList["title"] as? String == "Work")
        #expect(sourceList["objectUUID"] as? String == "L10")
        #expect(sourceList["requested"] as? String == "Work")
        #expect(sourceList["method"] as? String == "exact")
        #expect(sourceList["isGroceries"] as? Bool == false)
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "created")
        // No template seeded → no `template` key.
        #expect(obj["template"] == nil)
    }

    // MARK: - create: poll attaches the freshly created template when it appears
    //
    // The post-write poll re-opens a FRESH connection (mirroring Python's per-poll open_db()).
    // To faithfully simulate "the template appeared only AFTER the write" — without tripping the
    // pre-write duplicate-name check — the dup-check store is opened on a SMALL DB lacking the
    // template, while the poll re-opens the LARGER DB in the same dir (findMainDB picks the largest)
    // which DOES carry the freshly-created 'Weekly' template.

    @Test func createPollAttachesTemplate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func seed(_ name: String, withTemplate: Bool, pad: Int) throws {
            let q = try DatabaseQueue(path: dir.appendingPathComponent(name).path)
            try q.write { db in
                try FixtureDB.createRemindersSchema(db)
                try FixtureDB.createTemplateSchema(db)
                try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (10, 3, 'Work', 'L10', 0)")
                try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION) VALUES (100, 'a', 10, 1, 0, 0)")
                if withTemplate {
                    try db.execute(sql: "INSERT INTO ZREMCDTEMPLATE (Z_PK, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (50, 'Weekly', 'TW', 0)")
                }
                // Padding so the post-write DB is strictly larger (findMainDB picks the largest).
                for i in 0..<pad {
                    try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE, ZLIST, ZACCOUNT, ZCOMPLETED, ZMARKEDFORDELETION) VALUES (?, 'pad', 99, 1, 1, 1)", arguments: [1000 + i])
                }
            }
        }
        // SMALL DB (no 'Weekly' template) — opened FIRST as the passed store so dup-check passes.
        try seed("Data-small.sqlite", withTemplate: false, pad: 0)
        let s = try RemindersStore.open(storeDir: dir)   // picks the only DB so far (small)

        // LARGER DB (with the freshly-"created" 'Weekly' template) added AFTER the store opened.
        // The poll re-opens via findMainDB → picks the largest (this one) → finds the template.
        try seed("Data-large.sqlite", withTemplate: true, pad: 200)

        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["id": .string("TW")])

        let out = try await TemplateCreate.perform(
            name: "Weekly", fromList: "Work", fromListId: nil, includeCompleted: false,
            json: true, store: s, private: mock, pollAttempts: 1, pollDelay: 0)

        // The poll's fresh re-open attaches the 'Weekly' template that only appeared post-write.
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let template = try #require(obj["template"] as? [String: Any])
        #expect(template["id"] as? Int == 50)
        #expect(template["name"] as? String == "Weekly")
        #expect(template["objectUUID"] as? String == "TW")
    }

    // MARK: - create: helper failure

    @Test func createHelperFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "boom")

        let out = await WriteDispatch.perform {
            try await TemplateCreate.perform(
                name: "Weekly", fromList: "Work", fromListId: nil, includeCompleted: false,
                json: false, store: s, private: mock, pollAttempts: 1, pollDelay: 0)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Failed to create template 'Weekly': boom\n")
    }

    // MARK: - apply: happy path (no list re-read because helper id not in fixture)

    @Test func applyHappy() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["name": .string("Daily Copy")])

        let out = try await TemplateApply.perform(
            name: "Daily", templateId: nil, json: false, store: s, private: mock)

        #expect(out.exitCode == 0)
        // No `list` re-read → name falls back to result.name.
        #expect(out.stdout == "Created list from template: Daily Copy\n")
        // templateId sent to writer is the OBJECT UUID, not Z_PK.
        #expect(mock.calls == [.applyTemplate(templateId: "T40")])
    }

    // MARK: - apply: re-read attaches the new list when result.id matches a fixture list

    @Test func applyReReadAttachesList() async throws {
        // Seed the created list keyed by the ckid the helper returns.
        let (s, dir) = try store(extraBuild: { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (60, 3, 'Daily 2', 'NEWLIST', 0)")
        }); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["id": .string("NEWLIST"), "name": .string("ignored")])

        let out = try await TemplateApply.perform(
            name: "Daily", templateId: nil, json: true, store: s, private: mock)

        // indent=2.
        #expect(out.stdout.contains("\n  \"status\": \"created\""))
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["status"] as? String == "created")
        let template = try #require(obj["template"] as? [String: Any])
        #expect(template["id"] as? Int == 40)
        #expect(template["name"] as? String == "Daily")
        #expect(template["objectUUID"] as? String == "T40")
        let list = try #require(obj["list"] as? [String: Any])
        #expect(list["id"] as? Int == 60)
        #expect(list["title"] as? String == "Daily 2")
        #expect(list["objectUUID"] as? String == "NEWLIST")
    }

    // MARK: - apply: human name uses re-read list title when present

    @Test func applyHumanNameFromList() async throws {
        let (s, dir) = try store(extraBuild: { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION) VALUES (60, 3, 'Daily 2', 'NEWLIST', 0)")
        }); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["id": .string("NEWLIST"), "name": .string("ignored")])

        let out = try await TemplateApply.perform(
            name: "Daily", templateId: nil, json: false, store: s, private: mock)

        #expect(out.stdout == "Created list from template: Daily 2\n")
    }

    // MARK: - apply: helper failure

    @Test func applyHelperFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "nope")

        let out = await WriteDispatch.perform {
            try await TemplateApply.perform(
                name: "Daily", templateId: nil, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Failed to create list from template 'Daily': nope\n")
    }

    // MARK: - apply: template not found

    @Test func applyNotFound() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateApply.perform(
                name: "Ghost", templateId: nil, json: false, store: s, private: mock)
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: template not found: Ghost\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - delete: confirm accepted

    @Test func deleteConfirmed() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "deleted")
        var prompted = ""

        let out = try await TemplateDelete.perform(
            name: "Daily", templateId: nil, force: false, json: false,
            store: s, private: mock, confirm: { prompt in prompted = prompt; return true })

        #expect(prompted == "Delete template 'Daily'? [y/N] ")
        #expect(out.stdout == "Deleted template: Daily\n")
        #expect(mock.calls == [.deleteTemplate(templateId: "T40")])
    }

    // MARK: - delete: aborted (exit 0, NO JSON even with --json)

    @Test func deleteAborted() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()

        let out = try await TemplateDelete.perform(
            name: "Daily", templateId: nil, force: false, json: true,
            store: s, private: mock, confirm: { _ in false })

        #expect(out.exitCode == 0)
        #expect(out.stdout == "Aborted.\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - delete: --force skips confirm + COMPACT JSON

    @Test func deleteForceCompactJSON() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "deleted", fields: ["id": .string("T40")])
        var confirmCalled = false

        let out = try await TemplateDelete.perform(
            name: "Daily", templateId: nil, force: true, json: true,
            store: s, private: mock, confirm: { _ in confirmCalled = true; return true })

        #expect(confirmCalled == false)
        // COMPACT JSON: single line, no 2-space indentation (diverges from create/apply).
        #expect(!out.stdout.contains("\n  "))
        #expect(out.stdout.hasSuffix("}\n"))
        let obj = try #require(try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(obj["status"] as? String == "deleted")
        let template = try #require(obj["template"] as? [String: Any])
        #expect(template["id"] as? Int == 40)
        #expect(template["name"] as? String == "Daily")
        #expect(template["objectUUID"] as? String == "T40")
        let priv = try #require(obj["private"] as? [String: Any])
        #expect(priv["status"] as? String == "deleted")
        #expect(mock.calls == [.deleteTemplate(templateId: "T40")])
    }

    // MARK: - delete: by --template-id

    @Test func deleteByTemplateId() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "deleted")

        let out = try await TemplateDelete.perform(
            name: nil, templateId: 40, force: true, json: false,
            store: s, private: mock, confirm: { _ in true })

        #expect(out.stdout == "Deleted template: Daily\n")
        #expect(mock.calls == [.deleteTemplate(templateId: "T40")])
    }

    // MARK: - delete: not found

    @Test func deleteNotFound() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        let out = await WriteDispatch.perform {
            try await TemplateDelete.perform(
                name: "Ghost", templateId: nil, force: true, json: false,
                store: s, private: mock, confirm: { _ in true })
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: template not found: Ghost\n")
        #expect(mock.calls.isEmpty)
    }

    // MARK: - delete: helper failure

    @Test func deleteHelperFailure() async throws {
        let (s, dir) = try store(); defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "error", message: "denied")

        let out = await WriteDispatch.perform {
            try await TemplateDelete.perform(
                name: "Daily", templateId: nil, force: true, json: false,
                store: s, private: mock, confirm: { _ in true })
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Failed to delete template 'Daily': denied\n")
    }
}
