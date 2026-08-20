import Foundation

// Everything that used to be compiled in must now be absent by default, readable
// once set, and safe to leave empty.
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

MainActor.assumeIsolated {
    let s = AppSettings.shared
    s.resetAll()
    // resetAll clears the store; rebuild the in-memory copy the way a launch would.
    s.homeURL = ""; s.bookmarkFolder = ""; s.infrastructureHosts = []
    s.proxyHost = ""; s.qbBaseURL = ""
    s.nasHost = ""; s.nasShare = ""; s.nasUser = ""
    s.curatedMirrors = []

    print("Test 1 - nothing is configured out of the box")
    check("no home site", s.home == nil, "got \(s.homeURL)")
    check("no Firefox folder", s.bookmarkFolder.isEmpty)
    check("no infrastructure hosts", s.infrastructureHosts.isEmpty)
    check("no proxy", !s.proxyConfigured)
    check("no torrent client", !s.qbConfigured)
    check("no NAS", !s.nasConfigured)
    check("no mirror sets", s.curatedMirrors.isEmpty)

    print("Test 2 - an empty setup is still safe to use")
    check("a staging folder always resolves", !s.localRoot.path.isEmpty)
    check("an archive root always resolves", !Config.archiveRoot.isEmpty)
    check("every category still maps somewhere",
          Categoriser.alwaysShown.allSatisfy { !Config.categoryFolder($0.rawValue).isEmpty })
    check("Keychain services fall back to the bundle id",
          Config.qbKeychainService.hasPrefix(Config.bundleID)
          && Config.proxyKeychainService.hasPrefix(Config.bundleID),
          "\(Config.qbKeychainService) / \(Config.proxyKeychainService)")

    print("Test 3 - a partly filled NAS counts as none")
    s.nasHost = "nas.example"; s.nasShare = ""; s.nasUser = "someone"
    check("all three are required", !s.nasConfigured)
    check("and the thread-safe reader agrees", !Config.nasConfigured)
    s.nasShare = "Share"
    check("complete setup is recognised", s.nasConfigured && Config.nasConfigured)

    print("Test 4 - values round-trip")
    s.homeURL = "https://example.org/start"
    s.qbBaseURL = "http://client.example:8080/"
    s.curatedMirrors = [CuratedMirror(id: "demo", name: "Demo", page: "Some Article",
                                      urls: ["https://a.example/", "https://b.example/"])]
    check("home parses", s.home?.host == "example.org", "got \(String(describing: s.home))")
    check("client parses", s.qbBase?.port == 8080)
    let reread = (UserDefaults.standard.array(forKey: "mirrors.curated") as? [[String: Any]]) ?? []
    check("mirror set persisted", reread.count == 1, "got \(reread)")
    check("its article persisted", (reread.first?["page"] as? String) == "Some Article")
    check("its domains persisted", ((reread.first?["urls"] as? [String]) ?? []).count == 2)

    print("Test 5 - sites are drawn a little over life size")
    check("the default is 110%", AppSettings.defaultSiteZoom == 1.10,
          "got \(AppSettings.defaultSiteZoom)")
    check("an unconfigured launch starts there", Config.siteZoom == 1.10,
          "got \(Config.siteZoom)")
    s.siteZoom = 1.25
    check("a chosen zoom persists", UserDefaults.standard.double(forKey: "site.zoom") == 1.25)
    check("and a launch would read it back", Config.siteZoom == 1.25, "got \(Config.siteZoom)")
    // Settings is reached THROUGH the page, so an unreadable page is a locked door.
    s.siteZoom = 0
    check("zero cannot blank the page", s.effectiveSiteZoom >= 0.5, "got \(s.effectiveSiteZoom)")
    check("and a launch clamps it too", Config.siteZoom >= 0.5, "got \(Config.siteZoom)")
    s.siteZoom = 99
    check("nor can an absurd value", s.effectiveSiteZoom <= 3.0, "got \(s.effectiveSiteZoom)")
    check("clamped at launch as well", Config.siteZoom <= 3.0, "got \(Config.siteZoom)")
    s.siteZoom = AppSettings.defaultSiteZoom

    print("Test 6 - clearing a field removes it rather than storing a blank")
    s.homeURL = ""
    check("key removed", UserDefaults.standard.object(forKey: "home.url") == nil)
    check("and reads back as unset", s.home == nil)

    s.resetAll()
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
