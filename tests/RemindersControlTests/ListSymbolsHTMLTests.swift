import Testing
import Foundation
import AppKit
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// ListSymbolsHTMLTests — Phase 4 (Q6): list-symbols --html/--preview.
//
// The PURE builder buildListSymbolsHTML(rows:imageDataByAsset:) is tested with an
// injected imageDataByAsset dict so no private framework is needed. The impure
// AppKit export (exportBadgeAssets) hits the RemindersUICore private framework and
// is NOT exercised here — only the all-fallback path is CI-tested. The wiring core
// (ListSymbols.performHTML) is driven with injected env + open seam + exporter.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct ListSymbolsHTMLBuilderTests {

    /// A minimal valid 1x1 PNG, produced via the same AppKit path the real exporter uses.
    private static func onePixelPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test("all-fallback: no data:image URIs; well-formed; 10 swatches with uppercase hexes; blendRgb round-half-to-even")
    func buildAllFallback() {
        let html = buildListSymbolsHTML(rows: officialListSymbols, imageDataByAsset: [:])

        // Well-formed shell.
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<title>RemCTL Official Reminders List Symbols</title>"))
        #expect(html.contains("</html>"))

        // No image data anywhere — every card is a glyph fallback.
        #expect(!html.contains("data:image/png;base64,"))
        // Spot-check a couple of fallback glyphs appear as fallback spans.
        #expect(html.contains("<span class=\"fallback\">☺</span>"))   // default
        #expect(html.contains("<span class=\"fallback\">★</span>"))   // work5

        // The 71-symbol count badge.
        #expect(html.contains("<div class=\"count\">71 symbols</div>"))

        // All 10 base color hexes (uppercase) present as data-color.
        for hex in ["#FF2968", "#FF8D28", "#FFCC00", "#63DA38", "#0088FF",
                    "#CC73E1", "#A2845E", "#5B626A", "#5AC8FA", "#30B0C7"] {
            #expect(html.contains("data-color=\"\(hex)\""), "missing base hex \(hex)")
        }

        // blendRgb highlight hexes — exact, including the round-half-to-even ports.
        // green: 152.04→152(0x98), 230.58→231(0xE7), 123.66→124(0x7C) = #98E77C
        #expect(html.contains("data-highlight=\"#98E77C\""))
        // gray: 146.76→147(0x93), 151.38→151(0x97), 156.66→157(0x9D) = #93979D
        #expect(html.contains("data-highlight=\"#93979D\""))
        // teal: 118.38→118(0x76), 202.86→203(0xCB), 218.04→218(0xDA) = #76CBDA
        #expect(html.contains("data-highlight=\"#76CBDA\""))

        // Swatch order: red first (active second per Python: index==1 is orange).
        let redIdx = html.range(of: "title=\"red\"")?.lowerBound
        let orangeIdx = html.range(of: "title=\"orange\"")?.lowerBound
        let tealIdx = html.range(of: "title=\"teal\"")?.lowerBound
        #expect(redIdx != nil && orangeIdx != nil && tealIdx != nil)
        if let r = redIdx, let o = orangeIdx, let t = tealIdx {
            #expect(r < o)
            #expect(o < t)
        }
        // Only the second swatch (orange, index 1) is active / aria-pressed true.
        #expect(html.contains("aria-pressed=\"true\""))
    }

    @Test("with stub PNG: that asset's card carries a data:image URI; others fall back")
    func buildWithStubPNG() {
        let png = Self.onePixelPNG()
        // ListBadgeDefault is the asset for the `default` symbol.
        let html = buildListSymbolsHTML(rows: officialListSymbols,
                                        imageDataByAsset: ["ListBadgeDefault": png])
        let b64 = png.base64EncodedString()
        #expect(html.contains("<img alt=\"\" src=\"data:image/png;base64,\(b64)\">"))
        // The default symbol's fallback glyph must NOT appear (it got an image instead).
        #expect(!html.contains("<span class=\"fallback\">☺</span>"))
        // A non-injected asset still uses its fallback glyph.
        #expect(html.contains("<span class=\"fallback\">★</span>"))
    }

    @Test("escaping: & < > \" ' in a symbol name are HTML-escaped like Python html.escape")
    func escaping() {
        let rows = [Sym("a&b<c>d\"e'f", "Asset&<>\"'", "x")]
        let html = buildListSymbolsHTML(rows: rows, imageDataByAsset: [:])
        // Python html.escape escapes & < > " ' → &amp; &lt; &gt; &quot; &#x27;
        #expect(html.contains("<code>a&amp;b&lt;c&gt;d&quot;e&#x27;f</code>"))
        #expect(html.contains("<span>Asset&amp;&lt;&gt;&quot;&#x27;</span>"))
        // Raw unescaped forms must not leak.
        #expect(!html.contains("a&b<c>"))
    }
}

@Suite struct ListSymbolsHTMLWiringTests {

    private final class OpenRecorder {
        var calls: [[String]] = []
        func launch(_ args: [String]) { calls.append(args) }
    }

    private func tempConfigEnv() throws -> (tmp: URL, env: [String: String]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-list-symbols-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let configDir = tmp.appendingPathComponent("config")
        return (tmp, ["REMCTL_CONFIG_DIR": configDir.path])
    }

    @Test("--html <PATH> writes the file and prints HTML preview: <path>")
    func htmlWriteToPath() throws {
        let (tmp, env) = try tempConfigEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("nested/out.html")
        let rec = OpenRecorder()

        let outcome = try ListSymbols.performHTML(
            htmlArg: target.path, preview: false, env: env,
            exportAssets: { _ in [:] }, launch: rec.launch)

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == "HTML preview: \(target.path)\n")
        #expect(FileManager.default.fileExists(atPath: target.path))
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written.hasPrefix("<!doctype html>"))
        #expect(rec.calls.isEmpty)   // no --preview → no open
    }

    @Test("bare --html (empty value) → default CONFIG_DIR/list-symbols.html")
    func htmlBareDefaultsToConfigDir() throws {
        let (tmp, env) = try tempConfigEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expected = URL(fileURLWithPath: env["REMCTL_CONFIG_DIR"]!)
            .appendingPathComponent("list-symbols.html")
        let rec = OpenRecorder()

        let outcome = try ListSymbols.performHTML(
            htmlArg: "", preview: false, env: env,
            exportAssets: { _ in [:] }, launch: rec.launch)

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == "HTML preview: \(expected.path)\n")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("--html ~/... expands the tilde (against the process HOME, like Python expanduser)")
    func htmlTildeExpands() throws {
        let (tmp, env) = try tempConfigEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rec = OpenRecorder()

        // `~` expands against the real process HOME (NSString.expandingTildeInPath),
        // matching Python's Path.expanduser() — not the injected env dict. Use a unique
        // filename under HOME and clean it up so we don't pollute the home dir.
        let relName = ".remctl-test-\(UUID().uuidString).html"
        let expected = (("~/" + relName) as NSString).expandingTildeInPath
        defer { try? FileManager.default.removeItem(atPath: expected) }

        let outcome = try ListSymbols.performHTML(
            htmlArg: "~/" + relName, preview: false, env: env,
            exportAssets: { _ in [:] }, launch: rec.launch)

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == "HTML preview: \(expected)\n")
        #expect(FileManager.default.fileExists(atPath: expected))
        #expect(expected.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("--preview opens the written file via the injected open seam")
    func previewOpensViaSeam() throws {
        let (tmp, env) = try tempConfigEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("p.html")
        let rec = OpenRecorder()

        let outcome = try ListSymbols.performHTML(
            htmlArg: target.path, preview: true, env: env,
            exportAssets: { _ in [:] }, launch: rec.launch)

        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout == "HTML preview: \(target.path)\n")
        #expect(rec.calls == [[target.path]])
    }

    @Test("--preview with no --html opens the default CONFIG_DIR path")
    func previewDefaultPath() throws {
        let (tmp, env) = try tempConfigEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expected = URL(fileURLWithPath: env["REMCTL_CONFIG_DIR"]!)
            .appendingPathComponent("list-symbols.html")
        let rec = OpenRecorder()

        let outcome = try ListSymbols.performHTML(
            htmlArg: nil, preview: true, env: env,
            exportAssets: { _ in [:] }, launch: rec.launch)

        #expect(outcome.exitCode == 0)
        #expect(rec.calls == [[expected.path]])
    }

    @Test("argv normalizer injects const='' for a bare --html (nargs='?' parity)")
    func argvNormalizerInjectsEmptyForBareHtml() {
        typealias N = RemindersControl
        // Bare --html as last token → "" injected.
        #expect(N.normalizeListSymbolsHTMLArgs(["list-symbols", "--html"])
                == ["list-symbols", "--html", ""])
        // Bare --html before another option → "" injected between them.
        #expect(N.normalizeListSymbolsHTMLArgs(["list-symbols", "--html", "--preview"])
                == ["list-symbols", "--html", "", "--preview"])
        // --html PATH → untouched (PATH is a real value).
        #expect(N.normalizeListSymbolsHTMLArgs(["list-symbols", "--html", "out.html"])
                == ["list-symbols", "--html", "out.html"])
        // --html=PATH → untouched (single token).
        #expect(N.normalizeListSymbolsHTMLArgs(["list-symbols", "--html=out.html"])
                == ["list-symbols", "--html=out.html"])
        // Non-list-symbols invocation → untouched even with a --html-looking token.
        #expect(N.normalizeListSymbolsHTMLArgs(["lists", "--html"])
                == ["lists", "--html"])
        // No --html at all → untouched.
        #expect(N.normalizeListSymbolsHTMLArgs(["list-symbols", "--json"])
                == ["list-symbols", "--json"])
    }

    @Test("framework-missing degrade: empty export → all-fallback sheet, exit 0")
    func frameworkMissingDegrades() throws {
        let (tmp, env) = try tempConfigEnv()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("d.html")
        let rec = OpenRecorder()

        let outcome = try ListSymbols.performHTML(
            htmlArg: target.path, preview: false, env: env,
            exportAssets: { _ in [:] }, launch: rec.launch)

        #expect(outcome.exitCode == 0)
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(!written.contains("data:image/png;base64,"))
        #expect(written.contains("<span class=\"fallback\">"))
    }
}
