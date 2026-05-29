import Foundation

public struct Ansi {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }

    /// Resolve color suppression mirroring Python main():
    ///   --no-color || NO_COLOR present with non-empty value || stdout not a tty.
    ///
    /// Python uses `os.environ.get("NO_COLOR")` with truthiness semantics:
    /// an empty string is falsy and does NOT suppress color.
    public static func resolve(noColorFlag: Bool,
                               env: [String: String] = ProcessInfo.processInfo.environment,
                               isTTY: Bool = isatty(STDOUT_FILENO) != 0) -> Ansi {
        let noColorEnv = env["NO_COLOR"].map { !$0.isEmpty } ?? false
        return Ansi(enabled: !(noColorFlag || noColorEnv || !isTTY))
    }

    private func code(_ c: String, _ t: String) -> String { enabled ? "\u{1B}[\(c)m\(t)\u{1B}[0m" : t }
    public func red(_ t: String) -> String { code("31", t) }
    public func green(_ t: String) -> String { code("32", t) }
    public func yellow(_ t: String) -> String { code("33", t) }
    public func blue(_ t: String) -> String { code("34", t) }
    public func magenta(_ t: String) -> String { code("35", t) }
    public func cyan(_ t: String) -> String { code("36", t) }
    public func dim(_ t: String) -> String { code("2", t) }
    public func bold(_ t: String) -> String { code("1", t) }
    public func strikethrough(_ t: String) -> String { code("9", t) }
    public func rgb(_ r: Int, _ g: Int, _ b: Int, _ t: String) -> String {
        enabled ? "\u{1B}[38;2;\(r);\(g);\(b)m\(t)\u{1B}[0m" : t
    }
}

/// Replace terminal-control scalars with a single space; nil -> "".
/// Matches Python TERMINAL_CONTROL_RE = [\x00-\x1f\x7f-\x9f  ] (includes U+2028/U+2029).
public func safeDisplay(_ value: String?) -> String {
    guard let value else { return "" }
    var out = String.UnicodeScalarView()
    for s in value.unicodeScalars {
        if s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s.value == 0x2028 || s.value == 0x2029 {
            out.append("\u{20}")
        } else {
            out.append(s)
        }
    }
    return String(out)
}
