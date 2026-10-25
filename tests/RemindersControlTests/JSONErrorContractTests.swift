import Foundation
import GRDB
import Testing
@testable import RemindersControl

@Suite struct JSONErrorContractTests {
    struct Case: Sendable, CustomStringConvertible {
        let command: [String]
        let code: String
        let human: String
        let input: String?
        init(_ command: [String], _ code: String, _ human: String, input: String? = nil) {
            self.command = command; self.code = code; self.human = human; self.input = input
        }
        var description: String { command.joined(separator: " ") + " → " + code }
    }

    static let cases: [Case] = [
        Case(["show", "Unknown"], "list_not_found", "Error: list not found: Unknown\n"),
        Case(["add", "Task", "-l", "Unknown"], "list_not_found", "Error: list not found: Unknown\n"),
        Case(["show", "same"], "list_ambiguous", ""),
        Case(["list-info", "Group"], "list_is_group", ""),
        Case(["show"], "invalid_list_target", "Error: pass a list name or --list-id.\n"),
        Case(["info", "9999"], "not_found", "Error: #9999 not found\n"),
        Case(["subtasks", "9999"], "not_found", "Error: #9999 not found\n"),
        Case(["edit", "9999", "-n", "hello"], "not_found", "Error: #9999 not found\n"),
        Case(["done", "9999"], "not_found", "Error: #9999 not found\n"),
        Case(["add", "Task", "--recurrence", "impossible"], "invalid_recurrence", ""),
        Case(["add", "Task", "-l", "Work", "--assign", "Anyone"], "list_not_shared", "Error: target list has no sharees; assignment requires a shared list.\n"),
        Case(["add", "Task", "--alarm", "nonsense"], "invalid_alarm", "Error: could not parse alarm 'nonsense'. Use 15m, 1h, 1d, or an absolute date.\n"),
        Case(["add", "Task", "-p", "unlimited"], "invalid_priority", "Error: priority must be high, medium, low, or none.\n"),
        Case(["add", "Task", "-l", "Group"], "list_is_group", ""),
        Case(["add", "Task", "--early-reminder", "nonsense"], "invalid_early_reminder", "Error: --early-reminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.\n"),
        Case(["list-edit", "Work"], "invalid_list_edit", "Error: pass at least one of --new-name, --color, --symbol, --emoji, --groceries, --standard, or --grocery-locale.\n"),
        Case(["list-edit", "Work", "--new-name", "New"], "list_missing_identifier", "Error: target list has no stable CloudKit identifier.\n"),
        Case(["list-edit", "Work", "--color", "invisible"], "invalid_list_appearance", ""),
        Case(["list-pin", "NotHere"], "list_not_found", "Error: list or smart list not found: NotHere\n"),
        Case(["group-info", "Unknown"], "group_not_found", "Error: group not found: Unknown\n"),
        Case(["template-info", "Unknown"], "template_not_found", "Error: template not found: Unknown\n"),
        Case(["import", "-"], "invalid_import_json", "", input: "bad json"),
        Case(["import", "-"], "invalid_import", "Error: JSON must be an array of reminder objects\n", input: "{}"),
        Case(["import", "/no/such/file.json"], "import_file_not_found", "Error: File '/no/such/file.json' not found\n"),
        Case(["permissions", "unknown"], "unsupported_permissions_topic", "Error: Unsupported permissions topic 'unknown'\n"),
        Case(["list-symbols", "--preview"], "invalid_output_options", ""),
        Case(["upcoming", "0"], "invalid_days", "Error: upcoming days must be between 1 and 3650.\n"),
        Case(["smart-list-create", "Test", "--priority", "nonsense"], "invalid_smart_list_filter", ""),
    ]

    @Test(arguments: cases)
    func structuredFailure(test: Case) throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try FixtureDB.createTemplateSchema(db)
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (1,3,'Work',0),(2,3,'Same',0),(3,3,'SAME',0)")
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZISGROUP,ZMARKEDFORDELETION) VALUES (10,3,'Group',1,0)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try CLIRunner.run(test.command + ["--json"], storeDir: dir, stdin: test.input)
        #expect(result.exit != 0)
        #expect(result.stdout.isEmpty)
        let json = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        #expect(json?["status"] as? String == "error")
        #expect(json?["code"] as? String == test.code)
        #expect((json?["message"] as? String)?.count ?? 0 > 0)

        if test.command != ["list-symbols", "--preview"] {
            let plain = try CLIRunner.run(test.command, storeDir: dir, stdin: test.input)
            #expect(plain.exit != 0)
            #expect(plain.stdout.isEmpty)
            if !test.human.isEmpty {
                #expect(plain.stderr == test.human)
            } else if let message = json?["message"] as? String {
                #expect(plain.stderr == "Error: \(message)\n")
            }
        }
    }

    @Test func formatJSONResolvesListFailure() throws {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try CLIRunner.run(["show", "Missing", "--format", "json"], storeDir: dir)
        #expect(result.stdout.isEmpty)
        let payload = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        #expect(payload?["code"] as? String == "list_not_found")
    }

    @Test func unavailableDatabaseReportsCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remctl-missing-\(UUID().uuidString)")
        let result = try CLIRunner.run(["today", "--json"], storeDir: dir)
        #expect(result.exit != 0)
        #expect(result.stdout.isEmpty)
        let payload = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        #expect(payload?["code"] as? String == "database_unavailable")
    }
}

@Suite struct ErrorClassRenderingTests {
    struct Case: Sendable {
        let error: any Error
        let code: String
        let message: String
        let exit: Int32
    }

    @Test func typedAndUnexpectedErrors() throws {
        let unexpected = NSError(domain: "Sample", code: 7, userInfo: [NSLocalizedDescriptionKey: "unexpected error"])
        let cases: [Case] = [
            Case(error: CommandFailure("sample_failure", "sample"), code: "sample_failure", message: "sample", exit: 1),
            Case(error: CLIError("invalid choice", code: "invalid_request", context: [("field", .string("list"))]),
                 code: "invalid_request", message: "invalid choice", exit: 1),
            Case(error: CLIError("generic validation"), code: "invalid_request", message: "generic validation", exit: 1),
            Case(error: WriteError("write refused", exitCode: 2, code: "invalid_priority", context: [("input", .string("highest"))]),
                 code: "invalid_priority", message: "write refused", exit: 2),
            Case(error: RemindersDBUnavailable("No Reminders database found."), code: "database_unavailable",
                 message: "No Reminders database found.", exit: 1),
            Case(error: SmartListFilterError("unsupported filter"), code: "invalid_smart_list_filter",
                 message: "unsupported filter", exit: 1),
            Case(error: PrivateStepFailure(action: "flag", message: "private failed", completed: []),
                 code: "private_write_failed", message: "private failed", exit: 1),
            Case(error: unexpected, code: "command_failed", message: "\(unexpected)", exit: 1),
        ]
        for test in cases {
            let result = FailureRendering.outcome(test.error, json: true)
            #expect(result.exitCode == test.exit)
            #expect(result.stdout.isEmpty)
            let json = try #require(JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
            #expect(json["status"] as? String == "error")
            #expect(json["code"] as? String == test.code)
            #expect(json["message"] as? String == test.message)
            if test.code == "invalid_request" && test.message == "invalid choice" {
                #expect(json["field"] as? String == "list")
            }
            if test.code == "invalid_priority" {
                #expect(json["input"] as? String == "highest")
            }
            let human = FailureRendering.outcome(test.error, json: false)
            #expect(human.stderr == "Error: \(test.message)\n")
            #expect(human.stdout.isEmpty)
            #expect(human.exitCode == test.exit)
        }
    }
}
