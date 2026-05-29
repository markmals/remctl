import Foundation

/// Minimal JSON parser that preserves object key order, producing a JSONValue.
/// Used for filter/recurrence blob passthrough where key order must match the source bytes.
public enum OrderedJSON {
    public static func parse(_ data: Data) -> JSONValue? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let scalars = Array(s.unicodeScalars)
        var i = 0
        func skipWS() { while i < scalars.count, scalars[i] == " " || scalars[i] == "\n" || scalars[i] == "\t" || scalars[i] == "\r" { i += 1 } }
        func parseValue() -> JSONValue? {
            skipWS(); guard i < scalars.count else { return nil }
            switch scalars[i] {
            case "{": return parseObject()
            case "[": return parseArray()
            case "\"": return parseString().map { .string($0) }
            case "t": return parseLiteral("true", .bool(true))
            case "f": return parseLiteral("false", .bool(false))
            case "n": return parseLiteral("null", .null)
            default: return parseNumber()
            }
        }
        func parseLiteral(_ lit: String, _ v: JSONValue) -> JSONValue? {
            for c in lit.unicodeScalars { guard i < scalars.count, scalars[i] == c else { return nil }; i += 1 }
            return v
        }
        func parseString() -> String? {
            guard i < scalars.count, scalars[i] == "\"" else { return nil }; i += 1
            var out = String.UnicodeScalarView()
            while i < scalars.count {
                let c = scalars[i]; i += 1
                if c == "\"" { return String(out) }
                if c == "\\" {
                    guard i < scalars.count else { return nil }
                    let e = scalars[i]; i += 1
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        let hex = String(String.UnicodeScalarView(scalars[i..<min(i + 4, scalars.count)]))
                        i += 4
                        if let code = UInt32(hex, radix: 16) {
                            // handle surrogate pair
                            if (0xD800...0xDBFF).contains(code), i + 1 < scalars.count, scalars[i] == "\\", scalars[i + 1] == "u" {
                                let hex2 = String(String.UnicodeScalarView(scalars[(i + 2)..<min(i + 6, scalars.count)]))
                                if let low = UInt32(hex2, radix: 16), (0xDC00...0xDFFF).contains(low) {
                                    i += 6
                                    let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                                    if let sc = Unicode.Scalar(combined) { out.append(sc) }
                                } else if let sc = Unicode.Scalar(code) { out.append(sc) }
                            } else if let sc = Unicode.Scalar(code) { out.append(sc) }
                        }
                    default: out.append(e)
                    }
                } else { out.append(c) }
            }
            return nil
        }
        func parseNumber() -> JSONValue? {
            let start = i
            while i < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[i]) { i += 1 }
            let str = String(String.UnicodeScalarView(scalars[start..<i]))
            if !str.contains("."), !str.lowercased().contains("e"), let n = Int(str) { return .int(n) }
            if let d = Double(str) { return .double(d) }
            return nil
        }
        func parseArray() -> JSONValue? {
            i += 1; var items: [JSONValue] = []; skipWS()
            if i < scalars.count, scalars[i] == "]" { i += 1; return .array(items) }
            while true {
                guard let v = parseValue() else { return nil }; items.append(v); skipWS()
                guard i < scalars.count else { return nil }
                if scalars[i] == "," { i += 1; continue }
                if scalars[i] == "]" { i += 1; return .array(items) }
                return nil
            }
        }
        func parseObject() -> JSONValue? {
            i += 1; var pairs: [(String, JSONValue)] = []; skipWS()
            if i < scalars.count, scalars[i] == "}" { i += 1; return .object(pairs) }
            while true {
                skipWS(); guard let key = parseString() else { return nil }; skipWS()
                guard i < scalars.count, scalars[i] == ":" else { return nil }; i += 1
                guard let v = parseValue() else { return nil }; pairs.append((key, v)); skipWS()
                guard i < scalars.count else { return nil }
                if scalars[i] == "," { i += 1; continue }
                if scalars[i] == "}" { i += 1; return .object(pairs) }
                return nil
            }
        }
        let result = parseValue(); skipWS()
        guard i == scalars.count else { return nil }
        return result
    }
}
