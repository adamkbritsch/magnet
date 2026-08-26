import Foundation

let fixture = NSString(string: "~/x1337-app/tools/fixtures/fmhy-single-page.md").expandingTildeInPath
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}
func hosts(_ set: MirrorSet?) -> [String] { (set?.candidates ?? []).compactMap(\.host) }
func find(_ sets: [String: MirrorSet], domain: String) -> MirrorSet? {
    sets.values.first { $0.candidates.contains { $0.host.map(registrableDomain) == domain } }
}

print("Test 1 - a numbered link belongs to the NEAREST preceding named link")
// The trap: real lines carry several unrelated sites. [2] here is a mirror of B,
// not of A, and getting this wrong wires unrelated domains together.
let trap = "* [SiteA](https://aaa.example/), [SiteB](https://bbb.example/) / [2](https://bbb-mirror.example/) - Notes"
let trapped = FMHYList.parse(trap)
check("only one group survives", trapped.count == 1, "got \(trapped.values.map { hosts($0) })")
let bGroup = find(trapped, domain: "bbb.example")
check("the alternate attached to SiteB", hosts(bGroup).contains("bbb-mirror.example"), "got \(hosts(bGroup))")
check("SiteA was not given SiteB's mirror",
      !hosts(bGroup).contains("aaa.example"), "got \(hosts(bGroup))")

print("Test 2 - a lone site yields no group")
check("single-link line ignored", FMHYList.parse("* [Solo](https://solo.example/) - Notes").isEmpty)
check("non-list lines ignored", FMHYList.parse("# [Heading](https://h.example/), [2](https://h2.example/)").isEmpty)

print("Test 3 - Proxy counts as an alternate")
let px = FMHYList.parse("* [S](https://s.example/) / [Proxy](https://s-proxy.example/)")
check("proxy attached", hosts(px.values.first).contains("s-proxy.example"), "got \(px.values.map { hosts($0) })")

print("Test 4 - a domain claimed by two DIFFERENT groups is dropped")
let clash = FMHYList.parse("""
* [One](https://one.example/), [2](https://shared.example/)
* [Two](https://two.example/), [2](https://shared.example/)
""")
check("ambiguous groups discarded", clash.isEmpty, "got \(clash.values.map { hosts($0) })")

print("Test 5 - the same site listed twice is a duplicate, not a conflict")
let dupe = FMHYList.parse("""
* [Same](https://same.example/), [2](https://same-b.example/)
* [Same](https://same.example/), [2](https://same-b.example/)
""")
check("duplicate collapsed to one usable group", dupe.count == 1, "got \(dupe.values.map { hosts($0) })")

print("Test 6 - against the real published list")
let text = try! String(contentsOfFile: fixture, encoding: .utf8)
let sets = FMHYList.parse(text)
print("  parsed \(sets.count) usable mirror groups")
check("a substantial number of groups", sets.count > 200, "got \(sets.count)")

let x = find(sets, domain: "1337x.to")
check("1337x found", x != nil)
check("1337x carries its siblings",
      hosts(x).contains("x1337x.cc") && hosts(x).contains("1337x.st"), "got \(hosts(x))")
check("1337x did not absorb its status page",
      !hosts(x).contains { $0.contains("1337x-status") }, "got \(hosts(x))")
check("1337x did not absorb unrelated tool links",
      !hosts(x).contains { $0.contains("greasyfork") || $0.contains("github") || $0.contains("t.me") },
      "got \(hosts(x))")

let ru = find(sets, domain: "rutracker.org")
check("RuTracker found with its mirror", hosts(ru).contains("rutracker.net"), "got \(hosts(ru))")

let nyaa = find(sets, domain: "nyaa.si")
check("Nyaa found with mirrors", (hosts(nyaa).count) >= 2, "got \(hosts(nyaa))")

check("every group spans at least two real domains",
      sets.values.allSatisfy { Set($0.candidates.compactMap { $0.host.map(registrableDomain) }).count >= 2 })

print("\nA plain-HTTP bookmark is not a dead site")
// AudioBook Bay is the case this came from: the bookmarked host serves no TLS at all,
// so App Transport Security refuses it before the request leaves the process. That is
// not the site answering badly -- it is this domain being unreachable AS WRITTEN,
// which is exactly what another domain is for. Left out of the transport-failure set,
// the chip simply reported an error and never tried the domain that works.
check("an ATS refusal counts as a transport failure",
      WebFailure.isTransport(NSURLErrorAppTransportSecurityRequiresSecureConnection))
check("so does a dead host",
      WebFailure.isTransport(NSURLErrorCannotFindHost))
// A Cloudflare challenge is an HTTP answer and proves the domain is alive.
check("but an HTTP-level rejection is not",
      !WebFailure.isTransport(NSURLErrorBadServerResponse))
check("nor is a cancelled navigation",
      !WebFailure.isTransport(NSURLErrorCancelled))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
