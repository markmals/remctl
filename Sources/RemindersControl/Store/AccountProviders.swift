import Foundation
import GRDB

/// Resolves account providers by stable account identifier from the Accounts database,
/// so a renamed iCloud account is still recognized as iCloud (upstream e2cbc6b). The
/// Python CLI read this in its signed host and shipped the map to the bridge over JSON;
/// in-process we read the same table directly.
public enum AccountProviders {
    /// Identifiers are lowercased to match the EventKit source identifier case-insensitively.
    /// An account whose type (or whose parent chain) is an Apple account maps to
    /// `ListTargeting.appleAccountProvider`.
    static let sql = """
        WITH RECURSIVE icloud_accounts(id) AS (
        SELECT a.Z_PK FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK \
        WHERE t.ZIDENTIFIER = 'com.apple.account.AppleAccount' \
        UNION SELECT a.Z_PK FROM ZACCOUNT a JOIN icloud_accounts p ON a.ZPARENTACCOUNT = p.id) \
        SELECT a.ZIDENTIFIER AS identifier, CASE WHEN i.id IS NOT NULL THEN 'com.apple.account.AppleAccount' \
        ELSE t.ZIDENTIFIER END AS provider FROM ZACCOUNT a \
        JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK \
        LEFT JOIN icloud_accounts i ON a.Z_PK = i.id
        """

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
    }

    /// Lowercased account identifier → provider identifier. An unreadable Accounts database
    /// yields an empty map, which leaves the account-title fallback in charge.
    public static func load(path: String = defaultPath) -> [String: String] {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(1)
        guard let queue = try? DatabaseQueue(path: path, configuration: config),
              let rows = try? queue.read({ try Row.fetchAll($0, sql: sql) }) else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            guard let identifier = row.string("identifier"), !identifier.isEmpty,
                  let provider = row.string("provider"), !provider.isEmpty else { continue }
            result[identifier.lowercased()] = provider
        }
        return result
    }

    /// Process-wide cache. Upstream resolves the map once per command run; EventKit sources
    /// do not change mid-command.
    nonisolated(unsafe) private static var cache: [String: String]?

    public static var shared: [String: String] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }
}
