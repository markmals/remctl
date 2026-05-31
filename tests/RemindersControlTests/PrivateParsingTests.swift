import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// PrivateParsingTests – unit tests for P11 helpers:
//   parseEarlyReminder, splitCSV, parseSubtaskSpecs,
//   normalizeSectionId, normalizeImagePaths, resolveSectionCkid.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct PrivateParsingTests {

    // MARK: - parseEarlyReminder clear keywords

    @Test func earlyReminderClear_clear() throws {
        let r = try PrivateParsing.parseEarlyReminder("clear")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_none() throws {
        let r = try PrivateParsing.parseEarlyReminder("none")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_off() throws {
        let r = try PrivateParsing.parseEarlyReminder("off")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_never() throws {
        let r = try PrivateParsing.parseEarlyReminder("never")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_zero() throws {
        let r = try PrivateParsing.parseEarlyReminder("0")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_0m() throws {
        let r = try PrivateParsing.parseEarlyReminder("0m")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_0min() throws {
        let r = try PrivateParsing.parseEarlyReminder("0min")
        #expect(r == .clear(existingIdentifiers: []))
    }

    @Test func earlyReminderClear_caseInsensitive() throws {
        let r = try PrivateParsing.parseEarlyReminder("CLEAR")
        #expect(r == .clear(existingIdentifiers: []))
    }

    // MARK: - parseEarlyReminder set values

    @Test func earlyReminder_15m() throws {
        let r = try PrivateParsing.parseEarlyReminder("15m")
        #expect(r == .set(unit: 0, count: -15, existingIdentifiers: []))
    }

    @Test func earlyReminder_1min() throws {
        let r = try PrivateParsing.parseEarlyReminder("1min")
        #expect(r == .set(unit: 0, count: -1, existingIdentifiers: []))
    }

    @Test func earlyReminder_30minutes() throws {
        let r = try PrivateParsing.parseEarlyReminder("30minutes")
        #expect(r == .set(unit: 0, count: -30, existingIdentifiers: []))
    }

    @Test func earlyReminder_1h() throws {
        let r = try PrivateParsing.parseEarlyReminder("1h")
        #expect(r == .set(unit: 1, count: -1, existingIdentifiers: []))
    }

    @Test func earlyReminder_2hr() throws {
        let r = try PrivateParsing.parseEarlyReminder("2hr")
        #expect(r == .set(unit: 1, count: -2, existingIdentifiers: []))
    }

    @Test func earlyReminder_3hours() throws {
        let r = try PrivateParsing.parseEarlyReminder("3hours")
        #expect(r == .set(unit: 1, count: -3, existingIdentifiers: []))
    }

    @Test func earlyReminder_2d() throws {
        let r = try PrivateParsing.parseEarlyReminder("2d")
        #expect(r == .set(unit: 2, count: -2, existingIdentifiers: []))
    }

    @Test func earlyReminder_5days() throws {
        let r = try PrivateParsing.parseEarlyReminder("5days")
        #expect(r == .set(unit: 2, count: -5, existingIdentifiers: []))
    }

    @Test func earlyReminder_1w() throws {
        let r = try PrivateParsing.parseEarlyReminder("1w")
        #expect(r == .set(unit: 3, count: -1, existingIdentifiers: []))
    }

    @Test func earlyReminder_2wk() throws {
        let r = try PrivateParsing.parseEarlyReminder("2wk")
        #expect(r == .set(unit: 3, count: -2, existingIdentifiers: []))
    }

    @Test func earlyReminder_3weeks() throws {
        let r = try PrivateParsing.parseEarlyReminder("3weeks")
        #expect(r == .set(unit: 3, count: -3, existingIdentifiers: []))
    }

    @Test func earlyReminder_1mo() throws {
        let r = try PrivateParsing.parseEarlyReminder("1mo")
        #expect(r == .set(unit: 4, count: -1, existingIdentifiers: []))
    }

    @Test func earlyReminder_1month() throws {
        let r = try PrivateParsing.parseEarlyReminder("1month")
        #expect(r == .set(unit: 4, count: -1, existingIdentifiers: []))
    }

    @Test func earlyReminder_2months() throws {
        let r = try PrivateParsing.parseEarlyReminder("2months")
        #expect(r == .set(unit: 4, count: -2, existingIdentifiers: []))
    }

    @Test func earlyReminder_trailingBeforeStripped() throws {
        let r = try PrivateParsing.parseEarlyReminder("15 minutes before")
        #expect(r == .set(unit: 0, count: -15, existingIdentifiers: []))
    }

    @Test func earlyReminder_whitespace() throws {
        let r = try PrivateParsing.parseEarlyReminder("  1h  ")
        #expect(r == .set(unit: 1, count: -1, existingIdentifiers: []))
    }

    // MARK: - parseEarlyReminder invalid → throws

    @Test func earlyReminder_invalid_5x() {
        #expect(throws: CLIError.self) {
            try PrivateParsing.parseEarlyReminder("5x")
        }
    }

    @Test func earlyReminder_invalid_empty() {
        #expect(throws: CLIError.self) {
            try PrivateParsing.parseEarlyReminder("")
        }
    }

    @Test func earlyReminder_invalid_0h() {
        #expect(throws: CLIError.self) {
            try PrivateParsing.parseEarlyReminder("0h")
        }
    }

    @Test func earlyReminder_invalid_exact_message() {
        do {
            _ = try PrivateParsing.parseEarlyReminder("bad")
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "--early-reminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - splitCSV

    @Test func splitCSV_basic() {
        let result = PrivateParsing.splitCSV("#a, b ,#c")
        #expect(result == ["a", "b", "c"])
    }

    @Test func splitCSV_emptiesDropped() {
        let result = PrivateParsing.splitCSV(",,,")
        #expect(result == [])
    }

    @Test func splitCSV_emptyInput() {
        let result = PrivateParsing.splitCSV("")
        #expect(result == [])
    }

    @Test func splitCSV_noHash() {
        let result = PrivateParsing.splitCSV("foo, bar")
        #expect(result == ["foo", "bar"])
    }

    @Test func splitCSV_multipleLeadingHashes() {
        let result = PrivateParsing.splitCSV("##tag1, ##tag2")
        #expect(result == ["tag1", "tag2"])
    }

    @Test func splitCSV_singleItem() {
        let result = PrivateParsing.splitCSV("#work")
        #expect(result == ["work"])
    }

    // MARK: - normalizeSectionId

    @Test func normalizeSectionId_trailingSlashStripped() {
        let r = PrivateParsing.normalizeSectionId("x-apple.../ABC/")
        #expect(r == "ABC")
    }

    @Test func normalizeSectionId_plainId() {
        let r = PrivateParsing.normalizeSectionId("ABC123")
        #expect(r == "ABC123")
    }

    @Test func normalizeSectionId_emptyReturnsNil() {
        let r = PrivateParsing.normalizeSectionId("")
        #expect(r == nil)
    }

    @Test func normalizeSectionId_onlySlashes() {
        let r = PrivateParsing.normalizeSectionId("/")
        #expect(r == nil)
    }

    @Test func normalizeSectionId_multiSegment() {
        let r = PrivateParsing.normalizeSectionId("a/b/c/SEC1")
        #expect(r == "SEC1")
    }

    @Test func normalizeSectionId_noSlash() {
        let r = PrivateParsing.normalizeSectionId("SEC1")
        #expect(r == "SEC1")
    }

    // MARK: - normalizeImagePaths

    @Test func normalizeImagePaths_tilde() {
        let result = PrivateParsing.normalizeImagePaths(["~/x.png"])
        let home = NSHomeDirectory()
        #expect(result == ["\(home)/x.png"])
    }

    @Test func normalizeImagePaths_absoluteUnchanged() {
        let result = PrivateParsing.normalizeImagePaths(["/tmp/img.png"])
        #expect(result == ["/tmp/img.png"])
    }

    @Test func normalizeImagePaths_empty() {
        let result = PrivateParsing.normalizeImagePaths([])
        #expect(result == [])
    }

    @Test func normalizeImagePaths_dropsEmptyStrings() {
        let result = PrivateParsing.normalizeImagePaths(["", "  ", "/tmp/a.png"])
        #expect(result == ["/tmp/a.png"])
    }

    // MARK: - parseSubtaskSpecs

    @Test func parseSubtaskSpecs_bareTitle() throws {
        let result = try PrivateParsing.parseSubtaskSpecs(["Buy milk"])
        #expect(result.count == 1)
        #expect(result[0].title == "Buy milk")
        #expect(result[0].notes == nil)
    }

    @Test func parseSubtaskSpecs_jsonObject_basic() throws {
        let json = #"{"title":"Pay bills","notes":"Use app"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result.count == 1)
        #expect(result[0].title == "Pay bills")
        #expect(result[0].notes == "Use app")
    }

    @Test func parseSubtaskSpecs_jsonObject_withNotes() throws {
        let json = #"{"title":"Task","notes":"Some notes"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].notes == "Some notes")
    }

    @Test func parseSubtaskSpecs_jsonObject_withPriority() throws {
        let json = #"{"title":"Task","priority":"high"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].priority == "high")
    }

    @Test func parseSubtaskSpecs_invalidPriority_throws() {
        let json = #"{"title":"Task","priority":"urgent"}"#
        #expect(throws: CLIError.self) {
            try PrivateParsing.parseSubtaskSpecs([json])
        }
    }

    @Test func parseSubtaskSpecs_earlyReminder_camelCase() throws {
        let json = #"{"title":"Task","earlyReminder":"15m"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].earlyReminder == "15m")
    }

    @Test func parseSubtaskSpecs_earlyReminder_snakeCase() throws {
        let json = #"{"title":"Task","early_reminder":"1h"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].earlyReminder == "1h")
    }

    @Test func parseSubtaskSpecs_locationTitle_camelCase() throws {
        let json = #"{"title":"Task","latitude":37.5,"longitude":-122.0,"locationTitle":"Home"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].locationTitle == "Home")
    }

    @Test func parseSubtaskSpecs_locationTitle_snakeCase() throws {
        let json = #"{"title":"Task","latitude":37.5,"longitude":-122.0,"location_title":"Home"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].locationTitle == "Home")
    }

    @Test func parseSubtaskSpecs_address_throws() {
        let json = #"{"title":"Task","latitude":37.5,"longitude":-122.0,"address":"123 Main St"}"#
        do {
            _ = try PrivateParsing.parseSubtaskSpecs([json])
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "subtask location address is not currently supported.")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func parseSubtaskSpecs_missingTitle_throws() {
        let json = #"{"notes":"No title"}"#
        do {
            _ = try PrivateParsing.parseSubtaskSpecs([json])
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "each --subtask requires a non-empty title.")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func parseSubtaskSpecs_emptyTitle_throws() {
        let json = #"{"title":"  "}"#
        do {
            _ = try PrivateParsing.parseSubtaskSpecs([json])
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "each --subtask requires a non-empty title.")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func parseSubtaskSpecs_multiple() throws {
        let result = try PrivateParsing.parseSubtaskSpecs(["Task A", "Task B"])
        #expect(result.count == 2)
        #expect(result[0].title == "Task A")
        #expect(result[1].title == "Task B")
    }

    @Test func parseSubtaskSpecs_emptyStringsDropped() throws {
        let result = try PrivateParsing.parseSubtaskSpecs(["", "  ", "Valid"])
        #expect(result.count == 1)
        #expect(result[0].title == "Valid")
    }

    @Test func parseSubtaskSpecs_urlKey_snakeCase_url() throws {
        let json = #"{"title":"Task","url":"https://example.com"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].urls == ["https://example.com"])
    }

    @Test func parseSubtaskSpecs_invalidURL_throws() {
        let json = #"{"title":"Task","url":"ftp://example.com"}"#
        #expect(throws: CLIError.self) {
            try PrivateParsing.parseSubtaskSpecs([json])
        }
    }

    @Test func parseSubtaskSpecs_tags_csv() throws {
        // Using ##"..."## so the # chars in the JSON value are not raw-string terminators
        let json = ##"{"title":"Task","tags":"#work, #home"}"##
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].tags == ["work", "home"])
    }

    @Test func parseSubtaskSpecs_flagged_bool() throws {
        let json = #"{"title":"Task","flagged":true}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].flagged == true)
    }

    @Test func parseSubtaskSpecs_urgent_bool() throws {
        let json = #"{"title":"Task","urgent":false}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].urgent == false)
    }

    @Test func parseSubtaskSpecs_locationDefaults() throws {
        let json = #"{"title":"Task","latitude":37.5,"longitude":-122.0}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].latitude == 37.5)
        #expect(result[0].longitude == -122.0)
        #expect(result[0].radius == 100.0)
        #expect(result[0].proximity == 1)  // arriving
        #expect(result[0].locationTitle == "Location")
    }

    @Test func parseSubtaskSpecs_locationLeaving() throws {
        let json = #"{"title":"Task","latitude":37.5,"longitude":-122.0,"proximity":"leaving"}"#
        let result = try PrivateParsing.parseSubtaskSpecs([json])
        #expect(result[0].proximity == 2)
    }

    @Test func parseSubtaskSpecs_badEarlyReminder_throws() {
        let json = #"{"title":"Task","earlyReminder":"5x"}"#
        do {
            _ = try PrivateParsing.parseSubtaskSpecs([json])
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "subtask earlyReminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - resolveSectionCkid (fixture store)

    private func sectionStore() throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            // List pk=1
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION,
                    ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA)
                VALUES (1, 3, 'MyList', 'L1', 0, '{"memberships":[
                    {"groupID":"SEC-A","memberID":"R1"},
                    {"groupID":"SEC-A","memberID":"R2"},
                    {"groupID":"SEC-B","memberID":"R3"}
                ]}')
            """)
            // Sections for list 1
            try db.execute(sql: """
                INSERT INTO ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (10, 'Alpha', 1, 'SEC-A', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (20, 'Beta', 1, 'SEC-B', 0)
            """)
            // Duplicate name sections: "Gamma" appears twice
            try db.execute(sql: """
                INSERT INTO ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (30, 'Gamma', 1, 'SEC-G1', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (40, 'Gamma', 1, 'SEC-G2', 0)
            """)
        }
        let store = try RemindersStore.open(storeDir: dir)
        return (store, dir)
    }

    @Test func resolveSectionCkid_byId() throws {
        let (store, _) = try sectionStore()
        let ckid = try store.resolveSectionCkid(listPk: 1, sectionId: "SEC-A")
        #expect(ckid == "SEC-A")
    }

    @Test func resolveSectionCkid_byIdCaseInsensitive() throws {
        let (store, _) = try sectionStore()
        let ckid = try store.resolveSectionCkid(listPk: 1, sectionId: "sec-a")
        #expect(ckid == "SEC-A")
    }

    @Test func resolveSectionCkid_byIdWithTrailingSlash() throws {
        let (store, _) = try sectionStore()
        let ckid = try store.resolveSectionCkid(listPk: 1, sectionId: "x-apple.../SEC-B/")
        #expect(ckid == "SEC-B")
    }

    @Test func resolveSectionCkid_byIdNotFound_throws() {
        do {
            let (store, _) = try sectionStore()
            _ = try store.resolveSectionCkid(listPk: 1, sectionId: "NOT-EXIST")
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "section ID not found in target list: NOT-EXIST")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func resolveSectionCkid_byName_uniqueMatch() throws {
        let (store, _) = try sectionStore()
        let ckid = try store.resolveSectionCkid(listPk: 1, section: "Alpha")
        #expect(ckid == "SEC-A")
    }

    @Test func resolveSectionCkid_byName_caseInsensitive() throws {
        let (store, _) = try sectionStore()
        let ckid = try store.resolveSectionCkid(listPk: 1, section: "alpha")
        #expect(ckid == "SEC-A")
    }

    @Test func resolveSectionCkid_byName_notFound_throws() {
        do {
            let (store, _) = try sectionStore()
            _ = try store.resolveSectionCkid(listPk: 1, section: "Nonexistent")
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "section not found in target list: Nonexistent")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func resolveSectionCkid_byName_ambiguous_disambiguatedByMemberCount() throws {
        // "Gamma" has two sections: SEC-G1 (0 members), SEC-G2 (0 members)
        // Neither has members in the JSON blob, so both → throws ambiguous
        // But Alpha has 2 members (SEC-A) vs SEC-B has 1 — that's unique, not ambiguous
        let (store, _) = try sectionStore()
        // Gamma sections both have 0 members → ambiguous
        do {
            _ = try store.resolveSectionCkid(listPk: 1, section: "Gamma")
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message.contains("multiple sections named 'Gamma'"))
            #expect(e.message.contains("SEC-G1"))
            #expect(e.message.contains("SEC-G2"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func resolveSectionCkid_both_throws() {
        do {
            let (store, _) = try sectionStore()
            _ = try store.resolveSectionCkid(listPk: 1, section: "Alpha", sectionId: "SEC-A")
            Issue.record("expected throw")
        } catch let e as CLIError {
            #expect(e.message == "pass either --section or --section-id, not both.")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func resolveSectionCkid_neitherReturnsNil() throws {
        let (store, _) = try sectionStore()
        let result = try store.resolveSectionCkid(listPk: 1)
        #expect(result == nil)
    }

    // Test disambiguation: add a Gamma section with a member → unique non-empty → resolves
    @Test func resolveSectionCkid_ambiguous_disambiguatedByNonEmpty() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION,
                    ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA)
                VALUES (2, 3, 'L2', 'L2', 0, '{"memberships":[
                    {"groupID":"DUP-A","memberID":"R10"}
                ]}')
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (50, 'Dup', 2, 'DUP-A', 0)
            """)
            try db.execute(sql: """
                INSERT INTO ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)
                VALUES (60, 'Dup', 2, 'DUP-B', 0)
            """)
        }
        let store = try RemindersStore.open(storeDir: dir)
        // DUP-A has 1 member, DUP-B has 0 → resolves to DUP-A
        let ckid = try store.resolveSectionCkid(listPk: 2, section: "Dup")
        #expect(ckid == "DUP-A")
    }
}
