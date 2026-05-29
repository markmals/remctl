import GRDB
import Foundation

/// Tolerant column access mirroring Python `_row_get` (optional) vs subscript (required).
public protocol ReminderRow {
    func has(_ key: String) -> Bool
    func string(_ key: String) -> String?
    func int(_ key: String) -> Int?
    func double(_ key: String) -> Double?
    func data(_ key: String) -> Data?
}

extension GRDB.Row: ReminderRow {
    // `Row.index(forColumn:)` is `@usableFromInline` (internal to GRDB), so it is not
    // reachable from this module. The public `hasColumn(_:)` does the same thing
    // (case-insensitive presence check), so use it instead.
    public func has(_ key: String) -> Bool { hasColumn(key) }
    public func string(_ key: String) -> String? { has(key) ? self[key] : nil }
    public func int(_ key: String) -> Int? { has(key) ? self[key] : nil }
    public func double(_ key: String) -> Double? { has(key) ? self[key] : nil }
    public func data(_ key: String) -> Data? { has(key) ? self[key] : nil }
}

extension ReminderRow {
    /// Read a JSON-blob column tolerantly: TEXT if present, else BLOB decoded as UTF-8 (lossy,
    /// like Python `errors="replace"`). Mirrors Python `_json_blob` accepting both str and bytes.
    public func blobString(_ key: String) -> String? {
        if let s = string(key) { return s }
        if let d = data(key) { return String(decoding: d, as: UTF8.self) }
        return nil
    }
}
