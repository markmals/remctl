// The official Reminders list-badge symbol catalog, ported VERBATIM from
// `remctl` OFFICIAL_LIST_SYMBOLS (lines ~229-301). Preview glyphs are byte-exact
// (extracted from source, not transcribed). Order is the source order (non-alphabetical).
// 71 entries; the count is contractual.

public struct Sym: Sendable {
    public let name: String
    public let asset: String
    public let preview: String
    public init(_ name: String, _ asset: String, _ preview: String) {
        self.name = name; self.asset = asset; self.preview = preview
    }
}

public let officialListSymbols: [Sym] = [
    Sym("default", "ListBadgeDefault", "☺"),
    Sym("bookmarks1", "ListBadgeBookmarks1", "☷"),
    Sym("bookmarks2", "ListBadgeBookmarks2", "▮"),
    Sym("celebration1", "ListBadgeCelebration1", "🎁"),
    Sym("celebration2", "ListBadgeCelebration2", "🎂"),
    Sym("education1", "ListBadgeEducation1", "🎓"),
    Sym("education2", "ListBadgeEducation2", "🎒"),
    Sym("education3", "ListBadgeEducation3", "✎"),
    Sym("education4", "ListBadgeEducation4", "◰"),
    Sym("education5", "ListBadgeEducation5", "▰"),
    Sym("finance1", "ListBadgeFinance1", "💳"),
    Sym("finance2", "ListBadgeFinance2", "💵"),
    Sym("finance3", "ListBadgeFinance3", "▭"),
    Sym("fitness", "ListBadgeFitness", "🏋"),
    Sym("sport1", "ListBadgeSport1", "🏋"),
    Sym("sport2", "ListBadgeSport2", "🏃"),
    Sym("food", "ListBadgeFood", "🍴"),
    Sym("wine", "ListBadgeWine", "🍷"),
    Sym("health1", "ListBadgeHealth1", "💊"),
    Sym("health2", "ListBadgeHealth2", "🩺"),
    Sym("lifestyle1", "ListBadgeLifestyle1", "🪑"),
    Sym("location1", "ListBadgeLocation1", "⌂"),
    Sym("location2", "ListBadgeLocation2", "▦"),
    Sym("location3", "ListBadgeLocation3", "◫"),
    Sym("vacation", "ListBadgeVacation", "⛺"),
    Sym("media1", "ListBadgeMedia1", "▭"),
    Sym("media2", "ListBadgeMedia2", "♪"),
    Sym("media3", "ListBadgeMedia3", "▯"),
    Sym("media4", "ListBadgeMedia4", "🎮"),
    Sym("media5", "ListBadgeMedia5", "🎧"),
    Sym("nature1", "ListBadgeNature1", "☘"),
    Sym("nature2", "ListBadgeNature2", "🥕"),
    Sym("people1", "ListBadgePeople1", "♟"),
    Sym("people2", "ListBadgePeople2", "👥"),
    Sym("people3", "ListBadgePeople3", "👪"),
    Sym("pet1", "ListBadgePet1", "🐾"),
    Sym("pet2", "ListBadgePet2", "🧸"),
    Sym("pet3", "ListBadgePet3", "🐟"),
    Sym("shopping1", "ListBadgeShopping1", "▣"),
    Sym("shopping2", "ListBadgeShopping2", "🛒"),
    Sym("shopping3", "ListBadgeShopping3", "▥"),
    Sym("shopping4", "ListBadgeShopping4", "▧"),
    Sym("sport3", "ListBadgeSport3", "⚽"),
    Sym("sport4", "ListBadgeSport4", "⚾"),
    Sym("sport5", "ListBadgeSport5", "🏀"),
    Sym("sport6", "ListBadgeSport6", "🏈"),
    Sym("lifestyle2", "ListBadgeLifestyle2", "🎾"),
    Sym("transport1", "ListBadgeTransport1", "🚆"),
    Sym("transport2", "ListBadgeTransport2", "✈"),
    Sym("transport3", "ListBadgeTransport3", "⛵"),
    Sym("transport4", "ListBadgeTransport4", "🚗"),
    Sym("weather1", "ListBadgeWeather1", "☂"),
    Sym("weather2", "ListBadgeWeather2", "☀"),
    Sym("weather3", "ListBadgeWeather3", "☾"),
    Sym("weather4", "ListBadgeWeather4", "💧"),
    Sym("weather5", "ListBadgeWeather5", "❄"),
    Sym("concept1", "ListBadgeConcept1", "🔥"),
    Sym("work1", "ListBadgeWork1", "💼"),
    Sym("work2", "ListBadgeWork2", "🔧"),
    Sym("work3", "ListBadgeWork3", "✂"),
    Sym("concept2", "ListBadgeConcept2", "⌖"),
    Sym("symbol1", "ListBadgeSymbol1", "{}"),
    Sym("concept3", "ListBadgeConcept3", "💡"),
    Sym("symbol2", "ListBadgeSymbol2", "‼"),
    Sym("symbol3", "ListBadgeSymbol3", "*"),
    Sym("symbol4", "ListBadgeSymbol4", "■"),
    Sym("symbol5", "ListBadgeSymbol5", "●"),
    Sym("symbol6", "ListBadgeSymbol6", "▲"),
    Sym("symbol7", "ListBadgeSymbol7", "◆"),
    Sym("work4", "ListBadgeWork4", "♥"),
    Sym("work5", "ListBadgeWork5", "★"),
]

/// OFFICIAL_LIST_SYMBOL_NAMES (remctl:303): the set of valid badge names, for `--symbol` validation.
public let officialListSymbolNames: Set<String> = Set(officialListSymbols.map(\.name))

/// The note string emitted in `list-symbols --json` (verbatim from source).
public let listSymbolsNote =
    "These are Reminders' bundled list badge emblems; emoji badges are separate. " +
    "The preview field is an approximate Unicode text fallback, not the native Reminders/SF Symbol rendering."
