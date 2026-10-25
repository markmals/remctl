import Testing
import Foundation
import GRDB
@testable import RemindersControl

/// Accounts database → provider map used to recognize renamed iCloud accounts (upstream e2cbc6b).
@Suite struct AccountProvidersTests {
    /// Writes a minimal Accounts4-shaped database and returns its path.
    private func accountsDB(_ build: (Database) throws -> Void) throws -> (path: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Accounts4.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT);
            CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZACCOUNTTYPE INTEGER, ZPARENTACCOUNT INTEGER);
            """)
            try build(db)
        }
        return (path, dir)
    }

    @Test func appleAccountsAndTheirChildrenMapToTheAppleProvider() throws {
        let (path, dir) = try accountsDB { db in
            try db.execute(sql: "INSERT INTO ZACCOUNTTYPE (Z_PK, ZIDENTIFIER) VALUES (1, 'com.apple.account.AppleAccount')")
            try db.execute(sql: "INSERT INTO ZACCOUNTTYPE (Z_PK, ZIDENTIFIER) VALUES (2, 'com.apple.account.CalDAV')")
            try db.execute(sql: "INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTTYPE, ZPARENTACCOUNT) VALUES (1, 'Apple-Parent', 1, NULL)")
            // The Reminders CalDAV source hangs off the Apple account, so it is iCloud too.
            try db.execute(sql: "INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTTYPE, ZPARENTACCOUNT) VALUES (2, 'Reminders-Child', 2, 1)")
            try db.execute(sql: "INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTTYPE, ZPARENTACCOUNT) VALUES (3, 'Fastmail', 2, NULL)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let providers = AccountProviders.load(path: path)
        #expect(providers["apple-parent"] == ListTargeting.appleAccountProvider)
        #expect(providers["reminders-child"] == ListTargeting.appleAccountProvider)
        #expect(providers["fastmail"] == "com.apple.account.CalDAV")
    }

    @Test func missingAccountsDatabaseYieldsTheTitleFallback() {
        #expect(AccountProviders.load(path: "/nonexistent/Accounts4.sqlite").isEmpty)
    }
}
