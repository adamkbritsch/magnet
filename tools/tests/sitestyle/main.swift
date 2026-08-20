import Foundation
import WebKit

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

let css = SiteStyle.defaultCSS

/// The stylesheet with /* comments */ removed, so a guard checks actual rules rather
/// than prose. The sheet documents the selectors it deliberately avoids, and a naive
/// search finds those warnings and reports the very thing they warn about.
let rules: String = {
    var out = "", i = css.startIndex, depth = 0
    while i < css.endIndex {
        if css[i...].hasPrefix("/*") { depth += 1; i = css.index(i, offsetBy: 2); continue }
        if css[i...].hasPrefix("*/"), depth > 0 { depth -= 1; i = css.index(i, offsetBy: 2); continue }
        if depth == 0 { out.append(css[i]) }
        i = css.index(after: i)
    }
    return out
}()

print("Test 1 - nothing is injected when there is nothing to inject")
check("empty CSS yields no script", SiteStyle.userScript(css: "") == nil)
check("whitespace-only CSS yields no script", SiteStyle.userScript(css: "  \n\t ") == nil)
check("real CSS yields a script", SiteStyle.userScript(css: "body{color:red}") != nil)

print("Test 2 - the stylesheet cannot break out of the script that carries it")
// A sheet containing quotes, backslashes, newlines and a closing script tag would
// break naive string interpolation and could inject arbitrary JS.
let nasty = "a[href=\"x\"]::after { content: \"\\201C\"; }\n</script><script>alert(1)</script>"
guard let script = SiteStyle.userScript(css: nasty) else {
    print("  FAIL  no script produced"); exit(1)
}
let source = script.source
// Pull the JSON literal back out and confirm it round-trips to exactly the input.
if let open = source.range(of: "var css = "),
   let close = source.range(of: "[0];", range: open.upperBound..<source.endIndex) {
    let literal = String(source[open.upperBound..<close.lowerBound])
    let decoded = (try? JSONSerialization.jsonObject(with: Data(literal.utf8))) as? [String]
    check("CSS round-trips through the script unchanged", decoded?.first == nasty,
          "got \(decoded?.first ?? "nil")")
} else {
    check("script carries a JSON literal", false, "could not find it")
}
check("no raw closing script tag in the source", !source.contains("</script><script>"))

print("Test 3 - the script stamps the hostname so a site can be excepted")
check("sets data-x-host", source.contains("data-x-host"))
check("from location.hostname", source.contains("location.hostname"))
check("injects at document start",
      SiteStyle.userScript(css: "body{}")?.injectionTime == .atDocumentStart)

print("Test 4 - ICON SAFETY: the font rule must never use a universal or inline selector")
// Icon fonts declare font-family on the icon element itself. A declared value beats an
// inherited one, so setting the font on containers leaves icons alone -- but a `*`,
// `span` or `i` selector overrides them and turns every icon into a stray letter.
let blocks = css.components(separatedBy: "}")
let fontBlock = blocks.first { $0.contains("font-family: var(--x-font)") }
check("the font rule exists", fontBlock != nil)
if let fontBlock, let brace = fontBlock.range(of: "{") {
    let selectors = String(fontBlock[fontBlock.startIndex..<brace.lowerBound])
        .components(separatedBy: CharacterSet(charactersIn: ",\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("/*") && !$0.hasPrefix("*/") }
    let banned = ["*", "span", "i", "em", "b", "strong", "html"]
    let offenders = selectors.filter { banned.contains($0) }
    check("no universal or inline-text selectors", offenders.isEmpty, "found \(offenders)")
    check("still targets real containers",
          selectors.contains("body") && selectors.contains("td"), "got \(selectors.prefix(6))")
}

print("Test 5 - the theme is imposed, not inverted")
// Inversion was tried and abandoned: it gives every site a DIFFERENT palette (its own,
// flipped) when the goal is one palette everywhere, and it turns an already-dark site
// into glare. It also breaks position:fixed by putting a filter on <html>.
check("no filter anywhere in the sheet", !rules.contains("invert("), "inversion is back")
check("no hue-rotate either", !rules.contains("hue-rotate"), "inversion is back")
check("a page background is painted", rules.contains("--x-bg"))
check("a single text colour is imposed", rules.contains("--x-fg"))
check("links get their own accent", rules.contains("--x-link"))

print("Test 5b - REGRESSION: body itself must be coloured, not only its descendants")
// A descendant selector never matches the element it descends from, so `body :not(a)`
// leaves body's own colour alone and everything inheriting from it keeps the site's.
if let colourRule = rules.components(separatedBy: "}").first(where: {
    $0.contains("color: var(--x-fg)")
}), let brace = colourRule.range(of: "{") {
    let selectors = String(colourRule[colourRule.startIndex..<brace.lowerBound])
    // Split on commas: the selectors now carry a `:not(#\\9)` specificity chain, so a
    // literal "body," no longer appears even though body is targeted.
    let targeted = selectors.components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    check("body is targeted directly", targeted.contains { $0.hasPrefix("body") },
          targeted.joined(separator: " | "))
    check("the specificity chain is present, or site !important rules win",
          selectors.contains(":not(#"), "no specificity boost")
} else {
    check("the text colour rule exists", false)
}

print("Test 5c - REGRESSION: layout backgrounds are stripped, never re-inverted")
check("no background-image selector",
      !rules.contains("[style*=\"background-image\"]"), "it is back")
check("backgrounds are cleared on containers", rules.contains("background-image: none"))
check("comment stripping actually worked",
      rules.count < css.count && rules.contains("font-family: var(--x-font)"),
      "rules=\(rules.count) css=\(css.count)")

print("Test 6 - the page declares itself dark to the UA")
check("color-scheme is dark", rules.contains("color-scheme: dark"),
      rules.contains("color-scheme: light") ? "still forcing light, a leftover of inversion" : "missing")

print("Test 7 - the per-site escape hatch is documented in the sheet")
check("shows the exception form", css.contains("data-x-host=\"example.com\""))

print("Test 8 - every theme satisfies the full token contract")
// A rule referencing a token the palette forgot is dropped silently, and that part of
// the page simply keeps the site's own look.
let required = ["--x-bg", "--x-surface", "--x-surface-2", "--x-raised", "--x-fg",
                "--x-muted", "--x-link", "--x-link-hover", "--x-border", "--x-rule",
                "--x-zebra", "--x-hover", "--x-radius"]
for theme in SiteStyle.themes {
    let missing = required.filter { !theme.tokens.contains($0 + ":") }
    check("\(theme.name) defines every token", missing.isEmpty, "missing \(missing)")
    check("\(theme.name) declares a colour-scheme", theme.tokens.contains("color-scheme:"))
    check("\(theme.name) has three swatches", theme.swatches.count == 3)
}
check("five themes", SiteStyle.themes.count == 5, "got \(SiteStyle.themes.count)")

print("Test 8b - the themes are actually different from each other")
let pages = SiteStyle.themes.map { t -> String in
    guard let r = t.tokens.range(of: "--x-bg:") else { return t.id }
    return String(t.tokens[r.upperBound...].prefix(while: { $0 != ";" }))
        .trimmingCharacters(in: .whitespaces)
}
check("no two share a page colour", Set(pages).count == pages.count, "\(pages)")
let accents = SiteStyle.themes.map { t -> String in
    guard let r = t.tokens.range(of: "--x-link:") else { return t.id }
    return String(t.tokens[r.upperBound...].prefix(while: { $0 != ";" }))
        .trimmingCharacters(in: .whitespaces)
}
check("no two share an accent", Set(accents).count == accents.count, "\(accents)")
check("one of them is light",
      SiteStyle.themes.contains { $0.tokens.contains("color-scheme: light") })
let radii = Set(SiteStyle.themes.map { t -> String in
    guard let r = t.tokens.range(of: "--x-radius:") else { return t.id }
    return String(t.tokens[r.upperBound...].prefix(while: { $0 != ";" }))
})
check("corner radius varies too", radii.count >= 3, "\(radii)")

print("Test 8c - every theme still carries the whole structure")
for theme in SiteStyle.themes {
    let full = SiteStyle.css(for: theme.id)
    check("\(theme.name) keeps the icon-safe font rule",
          full.contains("font-family: var(--x-font)"))
    check("\(theme.name) keeps the specificity chain", full.contains(":not(#"))
    check("\(theme.name) resolves its own tokens", full.contains("--x-bg:"))
}
check("an unknown id falls back rather than yielding nothing",
      !SiteStyle.css(for: "nope").isEmpty && SiteStyle.css(for: "nope").contains("--x-bg:"))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
