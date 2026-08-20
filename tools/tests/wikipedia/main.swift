import Foundation

// Offline: parses a captured copy of the article so the suite does not depend on
// the network or on Wikipedia's current wording.
let fixture = NSString(string: "~/x1337-app/tools/fixtures/annas-archive.wikitext")
    .expandingTildeInPath
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

let wt = try! String(contentsOfFile: fixture, encoding: .utf8)

print("Test 1 - the infobox url field is isolated")
let field = WikipediaInfobox.infoboxField(named: "url", of: wt)
check("url field found", field != nil)
check("field is bounded, not the whole article", (field?.count ?? 0) < 2000, "len=\(field?.count ?? -1)")

print("Test 2 - only published domains are extracted")
let urls = WikipediaInfobox.parseURLTemplates(in: field ?? "")
check("three domains", urls.count == 3, "got \(urls)")
check("pk listed", urls.contains("https://annas-archive.pk/"), "got \(urls)")
check("gd listed", urls.contains("https://annas-archive.gd/"), "got \(urls)")
check("gl listed", urls.contains("https://annas-archive.gl/"), "got \(urls)")
check("upstream order preserved", urls.first == "https://annas-archive.pk/", "got \(urls)")

print("Test 3 - citations in the same field are not mistaken for domains")
check("no torrentfreak", !urls.contains { $0.contains("torrentfreak") }, "got \(urls)")
check("no vertsluisants", !urls.contains { $0.contains("vertsluisants") }, "got \(urls)")

print("Test 4 - parser shape")
check("bare domain gets a scheme",
      WikipediaInfobox.parseURLTemplates(in: "{{URL|example.org}}") == ["https://example.org"])
check("1= named parameter handled",
      WikipediaInfobox.parseURLTemplates(in: "{{URL|1=https://example.org/}}") == ["https://example.org/"])
check("duplicates collapsed",
      WikipediaInfobox.parseURLTemplates(in: "{{URL|https://a.org/}} {{URL|https://a.org/}}").count == 1)
check("empty field yields nothing", WikipediaInfobox.parseURLTemplates(in: "").isEmpty)
check("a field with no URL templates yields nothing",
      WikipediaInfobox.parseURLTemplates(in: "[https://example.org plain link]").isEmpty)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
