import Foundation
import GRDB

public struct RemindersDBUnavailable: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public enum Paths {
    static let defaultStoreSubpath =
        "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"

    @usableFromInline
    static func env() -> [String: String] { ProcessInfo.processInfo.environment }

    public static func resolveStoreDir(env e: [String: String] = env()) -> URL {
        if let v = e["REMCTL_STORE_DIR"], !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultStoreSubpath)
    }

    public static func resolveConfigDir(appName: String = "remctl", env e: [String: String] = env()) -> URL {
        if let v = e["REMCTL_CONFIG_DIR"], !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath) // as-is, no appName
        }
        if let x = e["XDG_CONFIG_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent(appName)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config").appendingPathComponent(appName)
    }

    /// Glob `Data-*.sqlite`, return the candidate with the highest CONTENT score
    /// (port of `reminders_db_score`, upstream aba7cf5). File size is only the final
    /// tie-break — a large-but-stale local store must not beat the live iCloud one.
    public static func findMainDBPath(storeDir: URL = resolveStoreDir()) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let candidates = items.filter {
            $0.lastPathComponent.hasPrefix("Data-") && $0.pathExtension == "sqlite"
        }
        return candidates.max { remindersDBScore($0) < remindersDBScore($1) }
    }
    private static func size(_ u: URL) -> Int {
        (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Lexicographically-compared score tuple, mirroring Python tuple comparison.
    struct DBScore: Comparable {
        let parts: [Double]
        static func == (a: DBScore, b: DBScore) -> Bool { a.parts == b.parts }
        static func < (a: DBScore, b: DBScore) -> Bool {
            for (x, y) in zip(a.parts, b.parts) where x != y { return x < y }
            return a.parts.count < b.parts.count
        }
    }

    /// Combined byte size of the WAL/SHM sidecars (port of `sqlite_sidecar_size`).
    static func sqliteSidecarSize(_ url: URL) -> Int {
        var total = 0
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            total += size(sidecar)
        }
        return total
    }

    /// Score a candidate store by read-only content: (hasReminderTable, reminderCount,
    /// activeCount, listCount, objectCount, latestModified, sidecarSize, dbSize).
    /// An unopenable/foreign file scores zeros ahead of the sizes, so any DB with the
    /// real schema always wins. Per-query failures degrade that component to 0.
    static func remindersDBScore(_ url: URL) -> DBScore {
        let dbSize = Double(size(url))
        let sidecar = Double(sqliteSidecarSize(url))
        var config = Configuration()
        config.readonly = true
        guard let q = try? DatabaseQueue(path: url.path, configuration: config) else {
            return DBScore(parts: [0, 0, 0, 0, 0, 0, sidecar, dbSize])
        }
        func scalar(_ db: Database, _ sql: String) -> Double {
            (try? Double.fetchOne(db, sql: sql)) ?? 0
        }
        let parts: [Double] = (try? q.read { db in
            let hasReminder = (try? db.tableExists("ZREMCDREMINDER")) ?? false
            let hasList = (try? db.tableExists("ZREMCDBASELIST")) ?? false
            let hasObject = (try? db.tableExists("ZREMCDOBJECT")) ?? false
            let reminderCount = hasReminder
                ? scalar(db, "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0") : 0
            let activeCount = hasReminder
                ? scalar(db, "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND COALESCE(ZCOMPLETED, 0) = 0") : 0
            let listCount = hasList
                ? scalar(db, "SELECT COUNT(*) FROM ZREMCDBASELIST WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND ZNAME IS NOT NULL AND ZNAME != ''") : 0
            let objectCount = hasObject
                ? scalar(db, "SELECT COUNT(*) FROM ZREMCDOBJECT WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0") : 0
            let latestModified = hasObject
                ? scalar(db, "SELECT MAX(COALESCE(ZMODIFIEDDATE, ZLASTMODIFIEDDATE, ZCREATIONDATE, 0)) FROM ZREMCDOBJECT") : 0
            return [hasReminder ? 1 : 0, reminderCount, activeCount, listCount, objectCount, latestModified, sidecar, dbSize]
        }) ?? [0, 0, 0, 0, 0, 0, sidecar, dbSize]
        return DBScore(parts: parts)
    }

    /// If store dir exists but is unreadable, returns the FDA-blocked message; else nil.
    public static func storeAccessError(storeDir: URL = resolveStoreDir()) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeDir.path) else { return nil }
        if fm.isReadableFile(atPath: storeDir.path) { return nil }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "remctl"
        return """
        Direct CLI reads are blocked because the Reminders store at \(storeDir.path) is not \
        readable from this process context (\(exe)). This usually means Full Disk Access is \
        missing for the app or interpreter that is running remctl here.
        """
    }

    public static func findMainDB(storeDir: URL = resolveStoreDir()) throws -> URL {
        if let err = storeAccessError(storeDir: storeDir) { throw RemindersDBUnavailable(err) }
        guard let p = findMainDBPath(storeDir: storeDir) else {
            throw RemindersDBUnavailable("No Reminders database found. Is iCloud Reminders enabled?")
        }
        return p
    }
}
