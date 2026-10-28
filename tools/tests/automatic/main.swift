import Foundation

// Automatic mode: what the NAS sends must decode however sparse it is, and the bar's
// sites must reach the NAS as one entry per site carrying every domain it goes by.

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

// The shape the NAS really returns: nulls where Sonarr is frozen, Prowlarr optional.
let overviewJSON = """
{"version": "1.0.0", "following": [
  {"id": 7, "tvdbId": 426606, "title": "Example Show", "year": 2026, "status": "continuing",
   "network": "Example Network", "monitored": true, "nextAiring": "2026-10-29T01:00:00Z",
   "previousAiring": null, "poster": null, "overview": "", "path": "/tv/Example Show (2026)",
   "magnetProfile": true}],
 "upcoming": [{"seriesId": 7, "series": "Example Show", "season": 1, "episode": 5, "title": "Five",
   "airDateUtc": "2026-10-29T01:00:00Z", "hasFile": false, "monitored": true}],
 "seedbox": {"torrents": [{"hash": "aa", "name": "Example.Show.S01E04.2160p.WEB-DL.DV.mkv", "state": "stoppedUP",
   "progress": 1.0, "size": 4649254842, "dlspeed": 0, "eta": 8640000, "addedOn": "2026-10-21T09:00:00Z",
   "completedOn": "2026-10-21T09:54:00Z", "verdict": "approved", "reason": "", "series": "Example Show",
   "season": 1, "episode": 4, "episodeTitle": "Four", "transferring": false, "onNAS": false,
   "score": 13575, "formats": ["DV Boost", "HDR", "2160p", "DD+ ATMOS", "WEB Tier 01"], "betterUntil": "2026-10-28T09:00:00Z"},
   {"hash": "bb", "name": "x", "state": "metaDL", "progress": 0, "size": null, "dlspeed": 0, "eta": null,
   "addedOn": null, "completedOn": null, "verdict": "held", "reason": "waiting for the file list",
   "series": null, "season": null, "episode": null, "episodeTitle": null, "transferring": false, "onNAS": false}],
   "freeBytes": 3100000000000, "minFreeBytes": 107374182400},
 "blocked": [{"hash": "cc", "name": "Fake.S01E05", "reason": "contains an executable (.scr)",
   "files": ["Fake/0000.scr"], "at": "2026-10-21T10:00:00Z", "blocklisted": false, "telling": true}],
 "transfers": [{"id": 1, "hash": "aa", "name": "x", "status": "failed", "command_id": 3, "message": "nope",
   "created": 1761040000.5, "updated": 1761040100.25}],
 "health": {"seedboxLogin": false, "seedboxBlocked": false, "seedboxError": "", "streaming": true,
   "lastPoll": null, "sonarr": false, "sonarrError": "Sonarr is paused while Plex is streaming", "freeBytes": null},
 "sources": {"sites": [{"name": "EZTV", "domains": ["eztvx.to"]}],
   "coverage": [{"site": "EZTV", "domains": ["eztvx.to"], "status": "searching", "detail": "already in Prowlarr",
                 "indexer": "EZTV"},
                {"site": "YTS", "domains": ["yts.mx"], "status": "no-tv", "detail": "this site has no TV to search",
                 "indexer": "YTS"}],
   "appliedAt": "2026-10-21T18:00:00Z", "pending": false, "error": ""}}
"""

print("Test 1 - the overview decodes, sparse fields and all")
do {
    let o = try JSONDecoder().decode(AutoOverview.self, from: Data(overviewJSON.utf8))
    check("one followed show", o.following.count == 1 && o.following[0].magnetProfile == true)
    check("next airing parses", o.following[0].nextDate != nil)
    check("episode code", o.upcoming[0].code == "S01E05", o.upcoming[0].code)
    check("a finished, approved download can come to the NAS", o.seedbox.torrents[0].canBringToNAS)
    check("a held one cannot", !o.seedbox.torrents[1].canBringToNAS)
    check("badges say what makes the copy good, Dolby Vision first",
          o.seedbox.torrents[0].badges.map(\.text) == ["Dolby Vision", "4K", "Atmos", "Top web group"],
          String(describing: o.seedbox.torrents[0].badges.map(\.text)))
    check("the better-copy window is read", o.seedbox.torrents[0].lookingUntil != nil)
    check("an older NAS without scores still decodes", o.seedbox.torrents[1].score == nil && o.seedbox.torrents[1].badges.isEmpty)
    check("blocked row keeps its reason and files", o.blocked[0].reason.contains(".scr") && o.blocked[0].files.count == 1)
    check("Sonarr frozen is reported, not fatal", o.health.sonarr == false && o.health.streaming == true)
    check("coverage explains itself",
          o.sources?.coverage[0].explanation == "Searched for new episodes (EZTV)"
          && o.sources?.coverage[1].explanation == "No TV on this site",
          String(describing: o.sources?.coverage.map(\.explanation)))
} catch {
    check("overview decodes", false, "\(error)")
}

print("Test 1b - a NAS that copies by itself shows the button only once it has given up")
do {
    func torrent(_ copy: String) -> String {
        overviewJSON.replacingOccurrences(of: #""episodeTitle": "Four", "transferring": false, "onNAS": false,"#,
                                          with: #""episodeTitle": "Four", "transferring": false, "onNAS": false, "copyStatus": "#
                                            + copy + #", "copyMessage": "","#)
            .replacingOccurrences(of: #""minFreeBytes": 107374182400}"#, with: #""minFreeBytes": 107374182400, "autoCopy": true}"#)
    }
    for (copy, button) in [("\"waiting\"", false), ("\"running\"", false), ("\"skipped\"", false),
                           ("\"done\"", false), ("\"failed\"", true)] {
        let o = try JSONDecoder().decode(AutoOverview.self, from: Data(torrent(copy).utf8))
        check("copy \(copy): Bring to NAS \(button ? "shown" : "hidden")",
              o.seedbox.torrents[0].canBringToNAS == button && o.seedbox.autoCopy == true,
              "copyStatus \(String(describing: o.seedbox.torrents[0].copyStatus))")
    }
    let old = try JSONDecoder().decode(AutoOverview.self, from: Data(overviewJSON.utf8))
    check("a NAS that never copies by itself keeps the button", old.seedbox.autoCopy == nil
          && old.seedbox.torrents[0].copyStatus == nil && old.seedbox.torrents[0].canBringToNAS)
} catch {
    check("auto-copy overview decodes", false, "\(error)")
}

print("Test 2 - an older NAS without the sources field still decodes")
do {
    let older = overviewJSON.replacingOccurrences(of: #""sources": {"sites""#, with: #""ignored": {"sites""#)
    let o = try JSONDecoder().decode(AutoOverview.self, from: Data(older.utf8))
    check("sources is optional", o.sources == nil)
} catch {
    check("older overview decodes", false, "\(error)")
}

MainActor.assumeIsolated {
    AppSettings.shared.resetAll()

    print("Test 3 - the bar's sites become sources")
    let bar = [Bookmark(title: "EZTV - TV Torrents", url: URL(string: "https://eztvx.to/")!),
               Bookmark(title: "YTS", url: URL(string: "https://yts.mx/browse-movies")!),
               Bookmark(title: "EZTV again", url: URL(string: "https://www.eztvx.to/shows")!),
               Bookmark(title: "Router", url: URL(string: "http://192.168.1.1/")!)]
    let home = URL(string: "https://1337x.example/home/")!
    let mirrors: (URL) -> [String] = { url in
        url.host == "1337x.example" ? ["1337x.example", "x1337x.example", "1337x.mirror.example"] : []
    }
    let sites = AutoSources.sites(from: bar, home: home, alsoKnownAs: mirrors)
    check("home leads, the router is not a site, the duplicate EZTV collapses",
          sites.map(\.name).count == 3, sites.map(\.name).joined(separator: ", "))
    check("home carries its mirrors",
          sites.first?.domains == ["1337x.example", "x1337x.example", "1337x.mirror.example"],
          String(describing: sites.first?.domains))
    check("a site's own host comes first", sites.dropFirst().first?.domains.first == "eztvx.to")
    let withChip = AutoSources.sites(from: [Bookmark(title: "1337x", url: home)] + bar, home: home, alsoKnownAs: mirrors)
    check("home is not added twice when a chip already points at it",
          withChip.filter { $0.domains.contains("1337x.example") }.count == 1)
    check("an empty bar and no home is an empty list", AutoSources.sites(from: [], home: nil, alsoKnownAs: mirrors).isEmpty)

    print("Test 4 - the signature ignores order")
    let a = [AutoSite(name: "A", domains: ["a.example", "b.example"]), AutoSite(name: "C", domains: ["c.example"])]
    let b = [AutoSite(name: "C", domains: ["c.example"]), AutoSite(name: "A", domains: ["b.example", "a.example"])]
    check("pinning or reordering chips does not resend", AutoSources.signature(a) == AutoSources.signature(b))
    check("a new site does", AutoSources.signature(a) != AutoSources.signature(a + [AutoSite(name: "D", domains: ["d.example"])]))

    print("Test 5 - settings")
    let s = AppSettings.shared
    check("Manual by default", s.mode == "manual" && !s.isAutomatic)
    check("no NAS service by default", s.automaticBase == nil && Config.automaticBase == nil)
    s.automaticServer = "not a url"
    check("a bare word is not an address", s.automaticBase == nil)
    s.automaticServer = "http://nas.example:8790"
    check("a real address is kept", s.automaticBase?.host == "nas.example" && Config.automaticBase?.port == 8790)
    s.mode = "automatic"
    check("mode persists", UserDefaults.standard.string(forKey: "ui.mode") == "automatic")
    s.resetAll()
    check("resetAll clears the new keys",
          UserDefaults.standard.string(forKey: "automatic.server") == nil
          && UserDefaults.standard.string(forKey: "ui.mode") == nil)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
