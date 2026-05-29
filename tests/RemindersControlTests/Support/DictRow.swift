import Foundation
@testable import RemindersControl

struct DictRow: ReminderRow {
    let values: [String: Any?]
    init(_ v: [String: Any?]) { values = v }
    func has(_ key: String) -> Bool { values.index(forKey: key) != nil }
    func string(_ key: String) -> String? { values[key].flatMap { $0 } as? String }
    func int(_ key: String) -> Int? {
        guard let v = values[key].flatMap({ $0 }) else { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }
    func double(_ key: String) -> Double? {
        guard let v = values[key].flatMap({ $0 }) else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
    func data(_ key: String) -> Data? { values[key].flatMap { $0 } as? Data }
}
