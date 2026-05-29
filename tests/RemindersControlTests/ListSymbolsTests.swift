import Testing
import Foundation
@testable import RemindersControl

@Suite struct ListSymbolsCatalogTests {
    @Test func catalogHasExactly71Entries() {
        #expect(officialListSymbols.count == 71)
    }
    @Test func knownEntriesByteExact() {
        let byName = Dictionary(uniqueKeysWithValues: officialListSymbols.map { ($0.name, $0) })
        #expect(byName["default"]?.asset == "ListBadgeDefault")
        #expect(byName["education3"]?.asset == "ListBadgeEducation3")
        #expect(byName["education3"]?.preview == "✎")
        #expect(byName["fitness"]?.asset == "ListBadgeFitness")
        #expect(byName["work5"]?.preview == "★")
        // ASCII-literal previews (not emoji)
        #expect(byName["symbol1"]?.preview == "{}")
        #expect(byName["symbol3"]?.preview == "*")
    }
    @Test func orderIsSourceOrderNonAlphabetical() {
        // fitness precedes sport1; concept2 (61) before symbol1 (62)
        let names = officialListSymbols.map { $0.name }
        #expect(names.firstIndex(of: "fitness")! < names.firstIndex(of: "sport1")!)
        #expect(names.first == "default")
        #expect(names.last == "work5")
    }
}

@Suite struct ListSymbolsCommandTests {
    @Test func jsonShape() throws {
        let r = try CLIRunner.run(["list-symbols", "--json"], storeDir: nil)
        #expect(r.exit == 0)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(d?["count"] as? Int == 71)
        #expect((d?["note"] as? String)?.contains("approximate Unicode text fallback") == true)
        let symbols = d?["symbols"] as? [[String: Any]]
        let names = symbols?.compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("education3"))
        #expect(names.contains("fitness"))
        #expect(symbols?.count == 71)
    }
    @Test func humanTUILabels() throws {
        let r = try CLIRunner.run(["list-symbols"], storeDir: nil)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Official Reminders list symbols (71):"))
        #expect(r.stdout.contains("approximate text fallback"))
        #expect(r.stdout.contains("remctl list-symbols --preview"))
        #expect(r.stdout.contains("approx"))
        #expect(r.stdout.contains("education3"))
    }
    @Test func humanHintDropsPrivateFlag() throws {
        // --private is removed in the Swift port; the hint must not mention it.
        let r = try CLIRunner.run(["list-symbols"], storeDir: nil)
        #expect(r.stdout.contains("remctl list-create \"Name\" --symbol <name>"))
        #expect(!r.stdout.contains("--private"))
    }
    @Test func jsonWithPreviewIsMutuallyExclusiveError() throws {
        let r = try CLIRunner.run(["list-symbols", "--json", "--preview"], storeDir: nil)
        #expect(r.exit == 1)
        #expect(r.stderr.contains("--json cannot be combined with --html or --preview"))
    }
}
