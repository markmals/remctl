import Foundation

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

    /// Glob `Data-*.sqlite`, return the LARGEST by file size (descending), or nil.
    public static func findMainDBPath(storeDir: URL = resolveStoreDir()) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let candidates = items.filter {
            $0.lastPathComponent.hasPrefix("Data-") && $0.pathExtension == "sqlite"
        }
        return candidates.max { size($0) < size($1) }
    }
    private static func size(_ u: URL) -> Int {
        (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
