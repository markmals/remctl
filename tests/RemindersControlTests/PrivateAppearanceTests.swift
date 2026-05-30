import Testing
import Foundation
@testable import RemindersControl

@Suite struct NormalizeListColorTests {
    @Test func hexUppercased() {
        #expect(normalizeListColor("#aabbcc") == "#AABBCC")
        #expect(normalizeListColor("#5ac8fa") == "#5AC8FA")
        #expect(normalizeListColor("  #AbCdEf  ") == "#ABCDEF")  // trims first
    }
    @Test func namedLowercased() {
        #expect(normalizeListColor("RED") == "red")
        #expect(normalizeListColor("Teal") == "teal")
        #expect(normalizeListColor("#ABC") == "#abc")  // 3-digit is NOT hex per ^#[0-9A-Fa-f]{6}$ -> lowercased
    }
}

@Suite struct NormalizeGroceryLocaleTests {
    @Test func normalizesLangAndRegion() throws {
        #expect(try normalizeGroceryLocale("en_US") == "en_US")
        #expect(try normalizeGroceryLocale("EN_us") == "en_US")
        #expect(try normalizeGroceryLocale("it-it") == "it_IT")   // dash -> underscore
        #expect(try normalizeGroceryLocale("fr") == "fr")          // lang only
        #expect(try normalizeGroceryLocale("  de_DE  ") == "de_DE")
    }
    @Test func badFormatThrows() {
        #expect(throws: CLIError.self) { _ = try normalizeGroceryLocale("english") }   // 7 letters, no region sep
        #expect(throws: CLIError.self) { _ = try normalizeGroceryLocale("e") }          // 1 letter
        #expect(throws: CLIError.self) { _ = try normalizeGroceryLocale("12_34") }      // digits in lang
        do { _ = try normalizeGroceryLocale("english"); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "--grocery-locale must look like en_US or it_IT.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func emptyThrows() {
        do { _ = try normalizeGroceryLocale("   "); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "--grocery-locale cannot be empty.") }
        catch { Issue.record("wrong error type") }
    }
}

@Suite struct ValidateListAppearanceTests {
    @Test func symbolAndEmojiTogether() {
        do { try validateListAppearanceArgs(color: nil, symbol: "education3", emoji: "🎓",
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "pass either --symbol or --emoji, not both.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func emptySymbol() {
        do { try validateListAppearanceArgs(color: nil, symbol: "  ", emoji: nil,
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "--symbol cannot be empty.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func emptyEmoji() {
        do { try validateListAppearanceArgs(color: nil, symbol: nil, emoji: "",
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "--emoji cannot be empty.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func unknownSymbolUsesPyRepr() {
        do { try validateListAppearanceArgs(color: nil, symbol: "nope", emoji: nil,
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError {
            #expect(e.message == "unsupported list symbol 'nope'. Run `remctl list-symbols` to see official names, or use --emoji for custom emoji badges.")
        }
        catch { Issue.record("wrong error type") }
    }
    @Test func unknownSymbolWithApostropheUsesDoubleQuoteRepr() {
        do { try validateListAppearanceArgs(color: nil, symbol: "it's", emoji: nil,
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError {
            #expect(e.message == "unsupported list symbol \"it's\". Run `remctl list-symbols` to see official names, or use --emoji for custom emoji badges.")
        }
        catch { Issue.record("wrong error type") }
    }
    @Test func knownSymbolAndEmojiAlwaysAllowed() throws {
        // --private gate dropped: a valid official symbol is accepted with no private opt-in.
        try validateListAppearanceArgs(color: nil, symbol: "education3", emoji: nil,
                                       groceries: false, standard: false, groceryLocale: nil)
        try validateListAppearanceArgs(color: nil, symbol: nil, emoji: "🎓",
                                       groceries: false, standard: false, groceryLocale: nil)
    }
    @Test func badColorHexAllowedMessage() {
        do { try validateListAppearanceArgs(color: "mauve", symbol: nil, emoji: nil,
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError {
            #expect(e.message == "unsupported list color 'mauve'. Use red, orange, yellow, green, blue, purple, brown, gray, cyan, or #RRGGBB.")
        }
        catch { Issue.record("wrong error type") }
    }
    @Test func colorErrorUsesOriginalValueNotNormalized() {
        // {value!r} uses the original, un-normalized value (e.g. mixed-case hex that fails the 6-digit check).
        do { try validateListAppearanceArgs(color: "#AbC", symbol: nil, emoji: nil,
                                            groceries: false, standard: false, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError {
            #expect(e.message == "unsupported list color '#AbC'. Use red, orange, yellow, green, blue, purple, brown, gray, cyan, or #RRGGBB.")
        }
        catch { Issue.record("wrong error type") }
    }
    @Test func hexColorAlwaysAllowed() throws {
        try validateListAppearanceArgs(color: "#5AC8FA", symbol: nil, emoji: nil,
                                       groceries: false, standard: false, groceryLocale: nil)
        try validateListAppearanceArgs(color: "teal", symbol: nil, emoji: nil,
                                       groceries: false, standard: false, groceryLocale: nil)  // teal IS in LIST_COLOR_MAP
    }
}

@Suite struct ValidateListGroceryTests {
    @Test func groceriesAndStandardTogether() {
        do { try validateListGroceryArgs(groceries: true, standard: true, groceryLocale: nil); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "pass either --groceries or --standard, not both.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func standardWithLocale() {
        do { try validateListGroceryArgs(groceries: false, standard: true, groceryLocale: "en_US"); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "--grocery-locale cannot be combined with --standard.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func localeValidatedWhenPresent() {
        do { try validateListGroceryArgs(groceries: true, standard: false, groceryLocale: "english"); Issue.record("should throw") }
        catch let e as CLIError { #expect(e.message == "--grocery-locale must look like en_US or it_IT.") }
        catch { Issue.record("wrong error type") }
    }
    @Test func validCombinationsPass() throws {
        try validateListGroceryArgs(groceries: true, standard: false, groceryLocale: "en_US")
        try validateListGroceryArgs(groceries: false, standard: true, groceryLocale: nil)
        try validateListGroceryArgs(groceries: false, standard: false, groceryLocale: "it_IT")
    }
}

@Suite struct BuildListAppearanceTests {
    @Test func nameColorSymbolTrimmed() {
        let a = buildListAppearance(newName: "Projects", color: "RED", symbol: "  education3  ",
                                    emoji: nil, groceries: false, standard: false, groceryLocale: nil)
        #expect(a.name == "Projects")
        #expect(a.color == "red")
        #expect(a.symbol == "education3")
        #expect(a.emoji == nil)
        #expect(a.shouldCategorizeGroceryItems == nil)
        #expect(a.groceryLocaleID == nil)
    }
    @Test func emojiTrimmedHexColorUppercased() {
        let a = buildListAppearance(newName: nil, color: "#aabbcc", symbol: nil,
                                    emoji: "  🎓  ", groceries: false, standard: false, groceryLocale: nil)
        #expect(a.name == nil)
        #expect(a.color == "#AABBCC")
        #expect(a.emoji == "🎓")
    }
    @Test func groceriesKeyPresence() {
        // groceries -> shouldCategorize=true + groceryLocaleID (default en_US when locale nil)
        let a = buildListAppearance(newName: nil, color: nil, symbol: nil, emoji: nil,
                                    groceries: true, standard: false, groceryLocale: nil)
        #expect(a.shouldCategorizeGroceryItems == true)
        #expect(a.groceryLocaleID == "en_US")
        let b = buildListAppearance(newName: nil, color: nil, symbol: nil, emoji: nil,
                                    groceries: true, standard: false, groceryLocale: "it-it")
        #expect(b.shouldCategorizeGroceryItems == true)
        #expect(b.groceryLocaleID == "it_IT")
    }
    @Test func standardKeyPresenceNoLocale() {
        // standard -> shouldCategorize=false and NO groceryLocaleID key
        let a = buildListAppearance(newName: nil, color: nil, symbol: nil, emoji: nil,
                                    groceries: false, standard: true, groceryLocale: nil)
        #expect(a.shouldCategorizeGroceryItems == false)
        #expect(a.groceryLocaleID == nil)
    }
    @Test func localeOnlyKeyPresence() {
        // neither groceries nor standard, but locale given -> only groceryLocaleID, no shouldCategorize key
        let a = buildListAppearance(newName: nil, color: nil, symbol: nil, emoji: nil,
                                    groceries: false, standard: false, groceryLocale: "fr-FR")
        #expect(a.shouldCategorizeGroceryItems == nil)
        #expect(a.groceryLocaleID == "fr_FR")
    }
    @Test func emptyWhenNothingGiven() {
        let a = buildListAppearance(newName: nil, color: nil, symbol: nil, emoji: nil,
                                    groceries: false, standard: false, groceryLocale: nil)
        #expect(a.isEmpty)
    }
}
