import Foundation

// Private list/smart-list appearance normalizers, validators, and the payload builder shared by
// list-edit / list-create / smart-list-create / smart-list-edit. Ports normalize_list_color
// (remctl:305), normalize_grocery_locale (remctl:2682), validate_list_appearance_args (remctl:2635),
// validate_list_grocery_args (remctl:2699), and list_private_appearance_payload (remctl:2716).
//
// PROJECT-WIDE: `--private` was removed; private capability is unconditional. Every Python
// "requires --private" check (symbols/emojis, grocery metadata) is therefore DROPPED — symbol,
// emoji, hex color, and grocery metadata are always allowed. The structural/format validations
// (with their exact strings) are preserved. For color, the hex-allowed (private) branch is the
// only branch: a named LIST_COLOR_MAP entry OR `#RRGGBB`.

/// The 10 named list colors (LIST_COLOR_MAP, remctl:214). Only the names are needed for validation.
let listColorNames: Set<String> = [
    "red", "orange", "yellow", "green", "blue", "purple", "brown", "gray", "cyan", "teal",
]

/// `^#[0-9A-Fa-f]{6}$` (HEX_COLOR_RE, remctl:227).
private let hexColorRegex = try! NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}$")
/// `^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})?$` (GROCERY_LOCALE_RE, remctl:2670).
private let groceryLocaleRegex = try! NSRegularExpression(pattern: "^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})?$")

private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// Default grocery locale (DEFAULT_GROCERY_LOCALE_ID, remctl:2671).
let defaultGroceryLocaleID = "en_US"

/// normalize_list_color (remctl:305): trim; `#RRGGBB` hex → uppercased; otherwise lowercased.
public func normalizeListColor(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if matches(hexColorRegex, trimmed) { return trimmed.uppercased() }
    return trimmed.lowercased()
}

/// normalize_grocery_locale (remctl:2682): trim (empty → throw), `-`→`_`, must match
/// GROCERY_LOCALE_RE (else throw), then lang.lowercased() + `_` + REGION.uppercased().
public func normalizeGroceryLocale(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { throw CLIError("--grocery-locale cannot be empty.") }
    let localeID = trimmed.replacingOccurrences(of: "-", with: "_")
    if !matches(groceryLocaleRegex, localeID) {
        throw CLIError("--grocery-locale must look like en_US or it_IT.")
    }
    let parts = localeID.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
        return "\(parts[0].lowercased())_\(parts[1].uppercased())"
    }
    return parts[0].lowercased()
}

/// validate_list_grocery_args (remctl:2699), with the `--private`-requiring branch DROPPED.
public func validateListGroceryArgs(groceries: Bool, standard: Bool, groceryLocale: String?) throws {
    if groceries && standard {
        throw CLIError("pass either --groceries or --standard, not both.")
    }
    if standard, let loc = groceryLocale, !loc.isEmpty {
        throw CLIError("--grocery-locale cannot be combined with --standard.")
    }
    if let loc = groceryLocale, !loc.isEmpty {
        _ = try normalizeGroceryLocale(loc)
    }
}

/// validate_list_appearance_args (remctl:2635), with the `--private`-requiring branch DROPPED.
/// symbol XOR emoji; non-empty; symbol must be an official badge name; color named-or-hex;
/// then grocery validation.
public func validateListAppearanceArgs(
    color: String?, symbol: String?, emoji: String?,
    groceries: Bool, standard: Bool, groceryLocale: String?
) throws {
    // Python `if symbol and emoji` tests truthiness — empty strings are falsy.
    if !(symbol ?? "").isEmpty && !(emoji ?? "").isEmpty {
        throw CLIError("pass either --symbol or --emoji, not both.")
    }
    // Python branches on `symbol is not None` / `emoji is not None` for the emptiness checks.
    if let symbol, symbol.trimmingCharacters(in: .whitespaces).isEmpty {
        throw CLIError("--symbol cannot be empty.")
    }
    if let emoji, emoji.trimmingCharacters(in: .whitespaces).isEmpty {
        throw CLIError("--emoji cannot be empty.")
    }
    if let symbol {
        let normalized = symbol.trimmingCharacters(in: .whitespaces)
        if !officialListSymbolNames.contains(normalized) {
            throw CLIError("unsupported list symbol \(WriteFormatting.pyRepr(normalized)). "
                + "Run `remctl list-symbols` to see official names, or use --emoji for custom emoji badges.")
        }
    }
    try validateListColor(color)
    try validateListGroceryArgs(groceries: groceries, standard: standard, groceryLocale: groceryLocale)
}

/// validate_list_color private-path branch (remctl:321): a value is OK iff its normalized form is a
/// named LIST_COLOR_MAP entry OR matches `#RRGGBB`. The error uses {value!r} (the ORIGINAL value,
/// not normalized) and the verbatim private examples string (note: teal is a valid color but is
/// intentionally absent from this name list, matching the source).
func validateListColor(_ value: String?) throws {
    guard let value, !value.isEmpty else { return }
    let normalized = normalizeListColor(value)
    let ok: Bool = {
        guard let normalized else { return false }
        return listColorNames.contains(normalized) || matches(hexColorRegex, normalized)
    }()
    if !ok {
        throw CLIError("unsupported list color \(WriteFormatting.pyRepr(value)). "
            + "Use red, orange, yellow, green, blue, purple, brown, gray, cyan, or #RRGGBB.")
    }
}

/// list_private_appearance_payload (remctl:2716) with the `--private` gate dropped (color is now
/// always emitted when present). Key-PRESENCE rules for grocery mirror the source exactly:
///   groceries → shouldCategorizeGroceryItems=true + groceryLocaleID=(locale or en_US)
///   standard  → shouldCategorizeGroceryItems=false (NO locale key)
///   locale-only (neither flag) → groceryLocaleID only (NO shouldCategorize key)
/// Symbol/emoji are trimmed. Throws only if a present grocery locale is malformed.
public func buildListAppearance(
    newName: String?, color: String?, symbol: String?, emoji: String?,
    groceries: Bool, standard: Bool, groceryLocale: String?
) -> ListAppearance {
    var a = ListAppearance()
    if let newName, !newName.isEmpty { a.name = newName }
    if let color, !color.isEmpty { a.color = normalizeListColor(color) }
    if let symbol, !symbol.isEmpty { a.symbol = symbol.trimmingCharacters(in: .whitespaces) }
    if let emoji, !emoji.isEmpty { a.emoji = emoji.trimmingCharacters(in: .whitespaces) }
    if groceries {
        a.shouldCategorizeGroceryItems = true
        // locale already validated by validateListGroceryArgs; tolerate by falling back to default.
        a.groceryLocaleID = (groceryLocale.flatMap { try? normalizeGroceryLocale($0) }) ?? defaultGroceryLocaleID
    } else if standard {
        a.shouldCategorizeGroceryItems = false
    } else if let loc = groceryLocale, !loc.isEmpty {
        a.groceryLocaleID = (try? normalizeGroceryLocale(loc))
    }
    return a
}
