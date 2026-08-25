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
    check("the default is 105%", AppSettings.defaultSiteZoom == 1.05,
          "got \(AppSettings.defaultSiteZoom)")
    check("an unconfigured launch starts there", Config.siteZoom == 1.05,
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

    print("Test 7 - the proxy is built from settings, not handed down")
    // The launch order was the bug: the home domain is chosen by probing it, and that
    // probe ran before any route existed, so it went out directly -- on a network
    // where direct is precisely what does not work, so the app rejected its own home
    // domain and opened a mirror. Building from settings removes the ordering
    // entirely; there is nothing left to be too early for.
    let store = UserDefaults.standard
    store.removeObject(forKey: "proxy.host")
    check("no proxy configured means no proxy configuration",
          ProxyRoute.configurations().isEmpty)
    store.set("proxy.invalid", forKey: "proxy.host")
    store.set(8899, forKey: "proxy.port")
    check("a configured proxy produces one, with no route store involved",
          ProxyRoute.configurations().count == 1)
    check("and a probe session carries it",
          !ProxyRoute.session().configuration.proxyConfigurations.isEmpty)
    check("the port reads back", Config.proxyPort == 8899, "\(Config.proxyPort)")
    store.set(0, forKey: "proxy.port")
    check("a zero port falls back rather than producing an invalid endpoint",
          Config.proxyPort == 8888, "\(Config.proxyPort)")
    store.set(70000, forKey: "proxy.port")
    check("and so does one out of range", Config.proxyPort == 8888, "\(Config.proxyPort)")

    s.resetAll()
    store.removeObject(forKey: "proxy.host")
    store.removeObject(forKey: "proxy.port")
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
