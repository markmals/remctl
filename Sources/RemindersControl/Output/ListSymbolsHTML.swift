import Foundation

// Phase 4 (Q6): the `list-symbols --html/--preview` HTML contact-sheet generator.
// Ports build_list_symbols_html (remctl:4803-5033) byte-faithfully, plus the color
// helpers rgb_to_hex (remctl:334), blend_rgb (remctl:337), list_color_preview_rows
// (remctl:340) and a Python-html.escape-compatible escaper.
//
// The pure builder is split out so it can be CI-tested with an injected
// imageDataByAsset dict; the impure AppKit asset export lives in ListSymbols.

// ── Color helpers ─────────────────────────────────────────────────────────────

/// The 10 named list colors IN INSERTION ORDER (LIST_COLOR_MAP, remctl:214). Swift
/// Dictionary is unordered, so the preview-row order is pinned here explicitly.
let listColorOrder: [(name: String, rgb: (Int, Int, Int))] = [
    ("red", (255, 41, 104)),
    ("orange", (255, 141, 40)),
    ("yellow", (255, 204, 0)),
    ("green", (99, 218, 56)),
    ("blue", (0, 136, 255)),
    ("purple", (204, 115, 225)),
    ("brown", (162, 132, 94)),
    ("gray", (91, 98, 106)),
    ("cyan", (90, 200, 250)),
    ("teal", (48, 176, 199)),
]

/// rgb_to_hex (remctl:334): `#{:02X}{:02X}{:02X}` — uppercase hex, zero-padded.
func rgbToHex(_ rgb: (Int, Int, Int)) -> String {
    String(format: "#%02X%02X%02X", rgb.0, rgb.1, rgb.2)
}

/// blend_rgb (remctl:337): channel + (target - channel) * amount, rounded to int.
/// Python `round()` uses banker's rounding (round-half-to-even); Swift's default
/// `rounded()` is half-away-from-zero, so `.toNearestOrEven` is used to match.
func blendRgb(_ rgb: (Int, Int, Int), target: (Int, Int, Int) = (255, 255, 255), amount: Double = 0.34) -> (Int, Int, Int) {
    func blend(_ c: Int, _ t: Int) -> Int {
        Int((Double(c) + (Double(t) - Double(c)) * amount).rounded(.toNearestOrEven))
    }
    return (blend(rgb.0, target.0), blend(rgb.1, target.1), blend(rgb.2, target.2))
}

/// list_color_preview_rows (remctl:340): {name, hex, highlight} over the 10 colors in order.
func listColorPreviewRows() -> [(name: String, hex: String, highlight: String)] {
    listColorOrder.map { entry in
        (name: entry.name, hex: rgbToHex(entry.rgb), highlight: rgbToHex(blendRgb(entry.rgb)))
    }
}

/// Matches Python `html.escape(s, quote=True)`: & < > " ' → &amp; &lt; &gt; &quot; &#x27;.
/// The `&` substitution MUST run first so the entities it inserts are not re-escaped.
func htmlEscape(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    out = out.replacingOccurrences(of: "'", with: "&#x27;")
    return out
}

// ── HTML builder ────────────────────────────────────────────────────────────

/// build_list_symbols_html (remctl:4803): the full standalone contact-sheet document.
/// `imageDataByAsset` maps an asset name to its PNG bytes; when present a card renders
/// a base64 data: URI, otherwise it falls back to the symbol's preview glyph span.
public func buildListSymbolsHTML(rows: [Sym], imageDataByAsset: [String: Data]) -> String {
    var swatches: [String] = []
    for (index, color) in listColorPreviewRows().enumerated() {
        let name = htmlEscape(color.name)
        let hexValue = htmlEscape(color.hex)
        let highlight = htmlEscape(color.highlight)
        let pressed = index == 1 ? "true" : "false"
        let activeClass = index == 1 ? " active" : ""
        swatches.append("""
        <button class="swatch\(activeClass)" type="button" aria-pressed="\(pressed)" data-color="\(hexValue)" data-highlight="\(highlight)" style="--swatch: \(hexValue);" title="\(name)">
          <span></span><strong>\(name)</strong>
        </button>
        """)
    }

    var cards: [String] = []
    for row in rows {
        let asset = htmlEscape(row.asset)
        let name = htmlEscape(row.name)
        let preview = htmlEscape(row.preview)
        let icon: String
        if let data = imageDataByAsset[row.asset] {
            icon = "<img alt=\"\" src=\"data:image/png;base64,\(data.base64EncodedString())\">"
        } else {
            icon = "<span class=\"fallback\">\(preview)</span>"
        }
        cards.append("""
        <article class="symbol">
          <div class="badge">\(icon)</div>
          <div class="meta">
            <code>\(name)</code>
            <span>\(asset)</span>
          </div>
        </article>
        """)
    }

    // NOTE: braces in the CSS/JS below are literal Swift text (no f-string escaping needed,
    // unlike Python). Only `\(...)` interpolations are substituted. `--private` is dropped
    // from the in-HTML usage hint for consistency with the plain-output hint.
    return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>RemCTL Official Reminders List Symbols</title>
    <style>
    :root {
      color-scheme: light dark;
      --bg: #f5f5f7;
      --text: #1d1d1f;
      --muted: #6e6e73;
      --card: rgba(255, 255, 255, .82);
      --line: rgba(0, 0, 0, .08);
      --badge: #ff9f0a;
      --badge-highlight: #ffc466;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #101012;
        --text: #f5f5f7;
        --muted: #a1a1a6;
        --card: rgba(34, 34, 38, .78);
        --line: rgba(255, 255, 255, .11);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    }
    main {
      max-width: 1180px;
      margin: 0 auto;
      padding: 34px 24px 44px;
    }
    header {
      margin-bottom: 22px;
    }
    h1 {
      margin: 0 0 6px;
      font-size: 28px;
      line-height: 1.1;
      letter-spacing: 0;
    }
    p {
      margin: 0;
      color: var(--muted);
      max-width: 780px;
    }
    .count {
      color: var(--muted);
      white-space: nowrap;
    }
    .toolbar {
      display: flex;
      justify-content: space-between;
      align-items: end;
      gap: 20px;
      margin-bottom: 18px;
    }
    .swatches {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      padding: 0;
      margin: 0;
      border: 0;
    }
    .swatches legend {
      width: 100%;
      margin: 0 0 2px;
      color: var(--muted);
      font-size: 12px;
    }
    .swatch {
      height: 34px;
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 5px 10px 5px 6px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--card);
      color: var(--text);
      font: inherit;
      cursor: pointer;
    }
    .swatch span {
      width: 20px;
      height: 20px;
      border-radius: 50%;
      background: var(--swatch);
      box-shadow: inset 0 -1px 0 rgba(0, 0, 0, .18);
    }
    .swatch strong {
      font-size: 12px;
      font-weight: 600;
    }
    .swatch.active {
      border-color: var(--badge);
      box-shadow: 0 0 0 2px color-mix(in srgb, var(--badge), transparent 72%);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(210px, 1fr));
      gap: 10px;
    }
    .symbol {
      min-height: 84px;
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 14px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--card);
    }
    .badge {
      width: 54px;
      height: 54px;
      flex: 0 0 54px;
      display: grid;
      place-items: center;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 28%, var(--badge-highlight), var(--badge) 68%);
      box-shadow: inset 0 -1px 0 rgba(0, 0, 0, .12), 0 3px 10px rgba(0, 0, 0, .12);
    }
    .badge img {
      width: 31px;
      height: 31px;
      object-fit: contain;
      filter: brightness(0) invert(1);
    }
    .fallback {
      color: white;
      font-size: 24px;
      line-height: 1;
    }
    .meta {
      min-width: 0;
      display: grid;
      gap: 3px;
    }
    code {
      font: 600 14px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
      overflow-wrap: anywhere;
    }
    .meta span {
      color: var(--muted);
      font: 12px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
      overflow-wrap: anywhere;
    }
    </style>
    </head>
    <body>
    <main>
      <header>
        <div class="toolbar">
          <div>
            <h1>Official Reminders List Symbols</h1>
            <p>These are the native badge assets bundled with RemindersUICore. Use the symbol name with <code>remctl list-create "Name" --symbol &lt;name&gt;</code>.</p>
          </div>
          <div class="count">\(rows.count) symbols</div>
        </div>
        <fieldset class="swatches">
          <legend>Preview official colors</legend>
    \(swatches.joined())
        </fieldset>
      </header>
      <section class="grid">
    \(cards.joined())
      </section>
    </main>
    <script>
    (() => {
      const root = document.documentElement;
      const buttons = [...document.querySelectorAll('.swatch')];
      function apply(button) {
        root.style.setProperty('--badge', button.dataset.color);
        root.style.setProperty('--badge-highlight', button.dataset.highlight);
        buttons.forEach(candidate => {
          const active = candidate === button;
          candidate.classList.toggle('active', active);
          candidate.setAttribute('aria-pressed', String(active));
        });
      }
      buttons.forEach(button => button.addEventListener('click', () => apply(button)));
      const active = document.querySelector('.swatch.active') || buttons[0];
      if (active) apply(active);
    })();
    </script>
    </body>
    </html>

    """
}
