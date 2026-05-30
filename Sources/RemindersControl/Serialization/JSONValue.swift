import Foundation

/// Insertion-ordered JSON value mirroring Python `json.dumps` output exactly.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Ordered key/value pairs — order is the output order (no sorting).
    case object([(String, JSONValue)])

    /// Serialize matching Python `json.dumps(value, indent: indent, ensure_ascii: ensureAscii)`.
    /// - indent: nil = compact with ", "/": " separators; non-nil = pretty with that many spaces.
    /// - ensureAscii: true escapes non-ASCII as \uXXXX (surrogate pairs for astral); false emits literal UTF-8.
    /// Forward slashes are NEVER escaped (matches Python). No trailing newline.
    public func serialized(indent: Int?, ensureAscii: Bool) -> String {
        var out = ""
        write(into: &out, indent: indent, ensureAscii: ensureAscii, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int?, ensureAscii: Bool, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += JSONValue.formatDouble(d)
        case .string(let s): out += JSONValue.encodeString(s, ensureAscii: ensureAscii)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            writeContainer(into: &out, open: "[", close: "]", count: items.count,
                           indent: indent, level: level) { i, o, childLevel in
                items[i].write(into: &o, indent: indent, ensureAscii: ensureAscii, level: childLevel)
            }
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            writeContainer(into: &out, open: "{", close: "}", count: pairs.count,
                           indent: indent, level: level) { i, o, childLevel in
                o += JSONValue.encodeString(pairs[i].0, ensureAscii: ensureAscii)
                o += ": "
                pairs[i].1.write(into: &o, indent: indent, ensureAscii: ensureAscii, level: childLevel)
            }
        }
    }

    private func writeContainer(into out: inout String, open: String, close: String, count: Int,
                                indent: Int?, level: Int,
                                element: (Int, inout String, Int) -> Void) {
        out += open
        let childLevel = level + 1
        let pad = indent.map { String(repeating: " ", count: $0 * childLevel) }
        let closePad = indent.map { String(repeating: " ", count: $0 * level) }
        for i in 0..<count {
            if i == 0 {
                if let pad { out += "\n" + pad }
            } else if let pad {
                out += ",\n" + pad
            } else {
                out += ", "
            }
            element(i, &out, childLevel)
        }
        if let closePad { out += "\n" + closePad }
        out += close
    }

    /// Mirror Python json string encoding: \", \\, \n, \r, \t, \b, \f, \uXXXX for other C0;
    /// non-ASCII -> \uXXXX (UTF-16 incl. surrogate pairs) when ensureAscii, else literal. '/' never escaped.
    static func encodeString(_ s: String, ensureAscii: Bool) -> String {
        var r = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if scalar.value < 0x20 {
                    r += String(format: "\\u%04x", scalar.value)
                } else if scalar.value < 0x80 || !ensureAscii {
                    r.unicodeScalars.append(scalar)
                } else {
                    for unit in String(scalar).utf16 { r += String(format: "\\u%04x", unit) }
                }
            }
        }
        r += "\""
        return r
    }

    /// Match Python repr of whole-number floats in json (123.0 -> "123.0").
    static func formatDouble(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return String(format: "%.1f", d)
        }
        return String(d)
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}
