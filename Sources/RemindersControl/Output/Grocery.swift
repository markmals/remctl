import Foundation

/// Grocery category -> emoji (ported VERBATIM from GROCERY_CATEGORY_EMOJI; emoji byte-exact).
public let groceryCategoryEmojiMap: [String: String] = [
    "Baby Care": "🍼",
    "Bakery": "🥐",
    "Baking Items": "🧁",
    "Beverages": "🧃",
    "Breads & Cereals": "🍞",
    "Canned Foods & Soups": "🥫",
    "Coffee & Tea": "☕",
    "Dairy, Eggs & Cheese": "🥛",
    "Deli": "🥪",
    "Frozen Foods": "🧊",
    "Household Items": "🧻",
    "Meat": "🥩",
    "Oils & Dressings": "🫒",
    "Pasta, Rice & Beans": "🍝",
    "Personal Care & Health": "🧴",
    "Pet Care": "🐾",
    "Produce": "🥬",
    "Sauces & Condiments": "🍯",
    "Seafood": "🦐",
    "Snacks & Candy": "🍿",
    "Spices & Seasonings": "🌶️",
    "Wine, Beer & Spirits": "🍷",
]

/// Minimal HTML entity unescape mirroring Python `html.unescape` for the entities that occur in
/// grocery section names (`&amp; &lt; &gt; &quot; &#39; &apos;` + numeric `&#NN;` / `&#xNN;`).
public func htmlUnescape(_ s: String) -> String {
    var out = s
    let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
    // Numeric entities first (so a literal '&' produced by &amp; isn't re-interpreted).
    out = replaceNumericEntities(out)
    for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
    return out
}

private func replaceNumericEntities(_ s: String) -> String {
    guard s.contains("&#") else { return s }
    var result = ""
    var rest = Substring(s)
    while let amp = rest.range(of: "&#") {
        result += rest[..<amp.lowerBound]
        let after = rest[amp.upperBound...]
        guard let semi = after.firstIndex(of: ";") else { result += rest[amp.lowerBound...]; rest = ""; break }
        let body = after[..<semi]
        var scalarValue: UInt32?
        if body.first == "x" || body.first == "X" {
            scalarValue = UInt32(body.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(body, radix: 10)
        }
        if let v = scalarValue, let sc = Unicode.Scalar(v) {
            result.unicodeScalars.append(sc)
        } else {
            result += "&#" + body + ";"
        }
        rest = after[after.index(after: semi)...]
    }
    result += rest
    return result
}

/// Port of grocery_category_emoji: unescape + strip, then map lookup. nil when not found.
public func groceryCategoryEmoji(_ sectionName: String?) -> String? {
    guard let sectionName, !sectionName.isEmpty else { return nil }
    let normalized = htmlUnescape(sectionName).trimmingCharacters(in: .whitespacesAndNewlines)
    return groceryCategoryEmojiMap[normalized]
}

/// Port of format_grocery_section_name: when groceries, unescape + strip + optional emoji prefix.
public func formatGrocerySectionName(_ sectionName: String, isGroceries: Bool) -> String {
    guard isGroceries else { return sectionName }
    let display = htmlUnescape(sectionName).trimmingCharacters(in: .whitespacesAndNewlines)
    if let emoji = groceryCategoryEmoji(sectionName) { return "\(emoji) \(display)" }
    return display
}
