import Foundation

// The catalogue and the sync plan. Both are pure, so both are checked without a
// network or a running qBittorrent.
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

func u(_ s: String) -> URL { URL(string: s)! }

print("Test 1 - the catalogue is internally consistent")
let all = SearchPluginCatalogue.all
check("it is not empty", !all.isEmpty)
check("every engine name is unique",
      Set(all.map(\.id)).count == all.count,
      "\(all.count) entries, \(Set(all.map(\.id)).count) names")

var owner: [String: String] = [:]
var clashes: [String] = []
for plugin in all {
    for domain in plugin.domains {
        if let taken = owner[domain], taken != plugin.id { clashes.append("\(domain): \(taken)/\(plugin.id)") }
        owner[domain] = plugin.id
    }
}
// Two plugins claiming one domain means which one you get depends on array order.
check("no domain is claimed by two plugins", clashes.isEmpty, clashes.joined(separator: ", "))
check("every entry lists at least one domain", all.allSatisfy { !$0.domains.isEmpty })
check("every source is an https URL",
      all.allSatisfy { ($0.sourceURL?.scheme == "https") },
      all.filter { $0.sourceURL?.scheme != "https" }.map(\.id).joined(separator: ", "))
check("every source is a .py file",
      all.allSatisfy { $0.source.hasSuffix(".py") },
      all.filter { !$0.source.hasSuffix(".py") }.map(\.id).joined(separator: ", "))
// A scheme or a path here would never match a registrable domain, so the entry would
// silently never fire.
check("domains are bare hostnames",
      all.allSatisfy { $0.domains.allSatisfy { !$0.contains("/") && !$0.contains(":") && $0.contains(".") } })
check("domains are lowercase",
      all.allSatisfy { $0.domains.allSatisfy { $0 == $0.lowercased() } })

// qBittorrent names an installed engine after the file it came from, and that name is
// what the sync compares against. If they disagree, the plugin is "missing" on every
// run and gets reinstalled forever -- silently, since each install succeeds.
var misnamed: [String] = []
for plugin in all {
    let stem = (plugin.source as NSString).lastPathComponent
        .replacingOccurrences(of: ".py", with: "")
    if stem != plugin.id { misnamed.append("\(plugin.id) != \(stem)") }
}
check("every engine name matches its file name", misnamed.isEmpty,
      misnamed.joined(separator: ", "))

print("Test 2 - a site with a plugin that is not installed gets one")
var plan = SearchPluginPlan.make(sites: [u("https://nyaa.si/")], installed: [])
check("one install planned", plan.install.map(\.id) == ["nyaasi"], "\(plan.install.map(\.id))")
check("nothing reported as covered", plan.covered.isEmpty)
check("nothing reported as unmatched", plan.unmatched.isEmpty)

print("Test 3 - a site already covered is left alone")
plan = SearchPluginPlan.make(sites: [u("https://nyaa.si/")], installed: ["nyaasi"])
check("no install planned", plan.install.isEmpty)
check("counted as covered", plan.covered.map(\.id) == ["nyaasi"])
check("the plan is a no-op", plan.isEmpty)

print("Test 4 - a site with no published plugin is named, not silently skipped")
plan = SearchPluginPlan.make(sites: [u("https://steamrip.com/"), u("https://knaben.org/")],
                             installed: [])
check("nothing to install", plan.install.isEmpty)
check("both are reported", Set(plan.unmatched) == ["steamrip.com", "knaben.org"],
      "\(plan.unmatched)")
let text = SearchPluginSync.summary(covered: 0, installed: [], failed: [], unmatched: plan.unmatched)
check("and the summary says so", text.contains("no published plugin"), text)

print("Test 5 - a bookmark saved at a mirror still finds its plugin")
// The bar holds whichever domain was alive when it was saved, which is routinely not
// the one the plugin's own catalogue entry is filed under.
plan = SearchPluginPlan.make(sites: [u("https://x1337x.cc/")], installed: [])
check("a listed mirror matches directly", plan.install.map(\.id) == ["leetx"], "\(plan.install.map(\.id))")

plan = SearchPluginPlan.make(sites: [u("https://1337x.unknown-mirror.test/")], installed: [],
                             alsoKnownAs: { _ in ["1337x.to", "x1337x.se"] })
check("an unlisted mirror matches through the mirror set",
      plan.install.map(\.id) == ["leetx"], "\(plan.install.map(\.id))")
check("and it is not also reported as unmatched", plan.unmatched.isEmpty, "\(plan.unmatched)")

print("Test 6 - one plugin is never planned twice")
plan = SearchPluginPlan.make(sites: [u("https://1337x.to/"), u("https://x1337x.cc/"),
                                     u("https://1337x.st/")], installed: [])
check("three mirrors of one site are one install", plan.install.count == 1, "\(plan.install.count)")

plan = SearchPluginPlan.make(sites: [u("https://nyaa.si/a"), u("https://nyaa.si/b")], installed: [])
check("the same domain twice is one install", plan.install.count == 1, "\(plan.install.count)")

print("Test 7 - degenerate input is safe")
plan = SearchPluginPlan.make(sites: [], installed: [])
check("no sites means no work", plan.install.isEmpty && plan.unmatched.isEmpty)
plan = SearchPluginPlan.make(sites: [u("magnet:?xt=urn:btih:abc")], installed: [])
check("a magnet link is not a site", plan.install.isEmpty && plan.unmatched.isEmpty,
      "\(plan.unmatched)")

print("Test 8 - the summary reports every outcome")
let full = SearchPluginSync.summary(covered: 2, installed: ["Nyaa"], failed: ["YTS"],
                                    unmatched: ["knaben.org"])
check("names what was added", full.contains("Nyaa"), full)
check("names what failed", full.contains("YTS"), full)
check("counts what was already there", full.contains("2 already installed"), full)
check("names what has no plugin", full.contains("knaben.org"), full)
check("an empty sync says so",
      SearchPluginSync.summary(covered: 0, installed: [], failed: [], unmatched: []) == "Nothing to do.")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
