import Foundation

/// Minimal CSV writer matching Python `csv.writer` default 'excel' dialect:
/// comma delimiter, `"` quotechar, QUOTE_MINIMAL (quote only when a field contains
/// comma / quote / CR / LF), `"` doubled to escape, and `\r\n` (CRLF) line terminator.
public enum CSV {
    public static func field(_ s: String) -> String {
        let needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        if !needsQuote { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Render rows to a single CSV string with CRLF terminators (including after the last row),
    /// matching Python `csv.writer(...).writerows(rows)` output.
    public static func writeRows(_ rows: [[String]]) -> String {
        var out = ""
        for row in rows {
            out += row.map(field).joined(separator: ",")
            out += "\r\n"
        }
        return out
    }
}
