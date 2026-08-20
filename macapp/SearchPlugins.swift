import Foundation

/// A published qBittorrent search plugin, and the sites it covers.
///
/// `id` is the engine name qBittorrent reports back once the plugin is installed --
/// taken from the class name inside the .py, not from the file name -- because that
/// is the only string the two sides can agree on. Getting it wrong means the plugin
/// is installed again on every sync.
struct SearchPluginSource: Identifiable, Equatable {
    let id: String
    let site: String
    /// Registrable domains this plugin serves. Mirrors are listed because a site is
    /// bookmarked at whichever domain was alive that week.
    let domains: [String]
    let source: String

    var sourceURL: URL? { URL(string: source) }
}

/// The sites Magnet knows how to hand to qBittorrent's search.
///
/// Every entry was fetched and checked before being written down: HTTP 200, a Python
/// class, and a `search` method. A catalogue of plausible-looking URLs would be worse
/// than no catalogue at all, because the failure is silent -- qBittorrent accepts an
/// install request for a URL that 404s and simply ends up with no plugin.
///
/// The URLs are compiled in and nothing else is ever installed. This app will not
/// fetch Python from an address a web page suggested.
enum SearchPluginCatalogue {
    static let all: [SearchPluginSource] = [
        SearchPluginSource(
            id: "leetx", site: "1337x",
            domains: ["1337x.to", "1337x.st", "x1337x.cc", "x1337x.ws", "x1337x.eu",
                      "x1337x.se", "1337x.is", "1337x.gd"],
            source: "https://raw.githubusercontent.com/v1k45/1337x-qBittorrent-search-plugin/master/leetx.py"),
        SearchPluginSource(
            id: "eztvx", site: "EZTV",
            domains: ["eztvx.to", "eztv.re", "eztv.wf", "eztv.tf", "eztv.yt", "eztv.ch"],
            source: "https://raw.githubusercontent.com/DrPurp/eztvx-qbittorrent-plugin/main/eztvx.py"),
        SearchPluginSource(
            id: "yts", site: "YTS",
            domains: ["yts.mx", "yts.bz", "yts.rs", "yts.lt", "yts.am", "yts.pm"],
            source: "https://codeberg.org/lazulyra/qbit-plugins/raw/branch/main/yts/yts.py"),
        SearchPluginSource(
            id: "nyaasi", site: "Nyaa",
            domains: ["nyaa.si", "nyaa.iss.one", "nyaa.land"],
            source: "https://raw.githubusercontent.com/MadeOfMagicAndWires/qBit-plugins/master/engines/nyaasi.py"),
        SearchPluginSource(
            id: "rutracker", site: "RuTracker",
            domains: ["rutracker.org", "rutracker.net", "rutracker.nl"],
            source: "https://raw.githubusercontent.com/imDMG/qBt_SE/master/engines/rutracker.py"),
        SearchPluginSource(
            id: "rutor", site: "Rutor",
            domains: ["rutor.info", "rutor.org"],
            source: "https://raw.githubusercontent.com/imDMG/qBt_SE/master/engines/rutor.py"),
        SearchPluginSource(
            id: "fitgirl_repacks", site: "FitGirl Repacks",
            domains: ["fitgirl-repacks.site"],
            source: "https://raw.githubusercontent.com/Bioux1/qbtSearchPlugins/main/fitgirl_repacks.py"),
        SearchPluginSource(
            id: "dodi_repacks", site: "DODI Repacks",
            domains: ["dodi-repacks.site", "dodi-repacks.download"],
            source: "https://raw.githubusercontent.com/Bioux1/qbtSearchPlugins/main/dodi_repacks.py"),
        SearchPluginSource(
            id: "onlinefix", site: "Online Fix",
            domains: ["online-fix.me"],
            source: "https://raw.githubusercontent.com/caiocinel/onlinefix-qbittorrent-plugin/main/onlinefix.py"),
        SearchPluginSource(
            id: "audiobookbay", site: "AudioBook Bay",
            domains: ["theaudiobookbay.se", "audiobookbay.is", "audiobookbay.lu",
                      "theaudiobookbay.com"],
            source: "https://raw.githubusercontent.com/nklido/qBittorrent_search_engines/master/engines/audiobookbay.py"),
        SearchPluginSource(
            id: "limetorrents", site: "LimeTorrents",
            domains: ["limetorrents.fun", "limetorrents.lol", "limetorrents.pro",
                      "limetorrents.cc", "limetorrents.info"],
            source: "https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/limetorrents.py"),
        SearchPluginSource(
            id: "torlock", site: "Torlock",
            domains: ["torlock.com", "torlock2.com"],
            source: "https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/torlock.py"),
        SearchPluginSource(
            id: "torrentproject", site: "Torrent Project",
            domains: ["torrentproject.com.se", "torrentproject2.com"],
            source: "https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/torrentproject.py"),
        SearchPluginSource(
            id: "torrentscsv", site: "Torrents-CSV",
            domains: ["torrents-csv.com", "torrents-csv.ml"],
            source: "https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/torrentscsv.py"),
        SearchPluginSource(
            id: "piratebay", site: "The Pirate Bay",
            domains: ["thepiratebay.org", "thepiratebay10.org", "tpb.party", "piratebayproxy.live"],
            source: "https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/piratebay.py"),
        SearchPluginSource(
            id: "solidtorrents", site: "Solid Torrents",
            domains: ["solidtorrents.to", "solidtorrents.net", "solidtorrents.eu"],
            source: "https://raw.githubusercontent.com/BurningMop/qBittorrent-Search-Plugins/refs/heads/main/solidtorrents.py"),
        SearchPluginSource(
            id: "bitsearch", site: "BitSearch",
            domains: ["bitsearch.to"],
            source: "https://raw.githubusercontent.com/BurningMop/qBittorrent-Search-Plugins/refs/heads/main/bitsearch.py"),
        SearchPluginSource(
            id: "therarbg", site: "TheRARBG",
            domains: ["therarbg.com", "therarbg.to", "rarbgdump.com"],
            source: "https://raw.githubusercontent.com/BurningMop/qBittorrent-Search-Plugins/refs/heads/main/therarbg.py"),
        SearchPluginSource(
            id: "torrentgalaxy", site: "TorrentGalaxy",
            domains: ["torrentgalaxy.to", "torrentgalaxy.mx", "tgx.rs"],
            source: "https://raw.githubusercontent.com/nindogo/qbtSearchScripts/master/torrentgalaxy.py"),
        SearchPluginSource(
            id: "kickasstorrents", site: "KickassTorrents",
            domains: ["katcr.to", "kickasstorrents.to", "kat.li"],
            source: "https://raw.githubusercontent.com/LightDestory/qBittorrent-Search-Plugins/master/src/engines/kickasstorrents.py"),
        SearchPluginSource(
            id: "torrentdownload", site: "TorrentDownload",
            domains: ["torrentdownload.info", "torrentdownloads.pro"],
            source: "https://raw.githubusercontent.com/LightDestory/qBittorrent-Search-Plugins/master/src/engines/torrentdownload.py"),
        SearchPluginSource(
            id: "snowfl", site: "Snowfl",
            domains: ["snowfl.com"],
            source: "https://raw.githubusercontent.com/LightDestory/qBittorrent-Search-Plugins/master/src/engines/snowfl.py"),
        SearchPluginSource(
            id: "glotorrents", site: "GloTorrents",
            domains: ["glodls.to", "gtdb.to", "glotorrents.com"],
            source: "https://raw.githubusercontent.com/LightDestory/qBittorrent-Search-Plugins/master/src/engines/glotorrents.py"),
        SearchPluginSource(
            id: "yourbittorrent", site: "YourBittorrent",
            domains: ["yourbittorrent.com"],
            source: "https://raw.githubusercontent.com/LightDestory/qBittorrent-Search-Plugins/master/src/engines/yourbittorrent.py"),
        SearchPluginSource(
            id: "academictorrents", site: "Academic Torrents",
            domains: ["academictorrents.com"],
            source: "https://raw.githubusercontent.com/LightDestory/qBittorrent-Search-Plugins/master/src/engines/academictorrents.py"),
        SearchPluginSource(
            id: "btdig", site: "BTDigg",
            domains: ["btdig.com"],
            source: "https://raw.githubusercontent.com/galaris/BTDigg-qBittorrent-plugin/main/btdig.py"),
        SearchPluginSource(
            id: "magnetdl", site: "MagnetDL",
            domains: ["magnetdl.com"],
            source: "https://raw.githubusercontent.com/nindogo/qbtSearchScripts/master/magnetdl.py"),
        SearchPluginSource(
            id: "zooqle", site: "Zooqle",
            domains: ["zooqle.com", "zooqle.skin"],
            source: "https://raw.githubusercontent.com/444995/qbit-search-plugins/main/engines/zooqle.py"),
        SearchPluginSource(
            id: "animetosho", site: "Anime Tosho",
            domains: ["animetosho.org"],
            source: "https://raw.githubusercontent.com/AlaaBrahim/qBitTorrent-animetosho-search-plugin/main/animetosho.py"),
        SearchPluginSource(
            id: "tokyotoshokan", site: "Tokyo Toshokan",
            domains: ["tokyotosho.info"],
            source: "https://raw.githubusercontent.com/BrunoReX/qBittorrent-Search-Plugin-TokyoToshokan/master/tokyotoshokan.py"),
    ]

    /// The plugin covering a domain, if there is one.
    static func plugin(forDomain domain: String) -> SearchPluginSource? {
        let d = domain.lowercased()
        return all.first { $0.domains.contains(d) }
    }
}

/// What a sync would do, worked out without touching the network so it can be tested.
struct SearchPluginPlan: Equatable {
    /// Plugins to install: a site is in the bar and qBittorrent does not have it yet.
    var install: [SearchPluginSource] = []
    /// Sites already covered. Not an error -- this is the steady state.
    var covered: [SearchPluginSource] = []
    /// Sites with no published plugin at all. Worth naming rather than passing over
    /// in silence, or "sync complete" reads as "all your sites are searchable".
    var unmatched: [String] = []

    var isEmpty: Bool { install.isEmpty }

    /// - Parameters:
    ///   - sites: every site in the bar.
    ///   - installed: engine names qBittorrent already reports, whatever their state.
    ///   - alsoKnownAs: mirror domains for a site, so a bookmark saved at whichever
    ///     domain was alive that week still finds its plugin.
    static func make(sites: [URL],
                     installed: Set<String>,
                     alsoKnownAs: (URL) -> [String] = { _ in [] }) -> SearchPluginPlan {
        var plan = SearchPluginPlan()
        var seenPlugins = Set<String>()
        var seenSites = Set<String>()

        for site in sites {
            guard let host = site.host else { continue }
            let primary = registrableDomain(host)
            guard !seenSites.contains(primary) else { continue }
            seenSites.insert(primary)

            let candidates = [primary] + alsoKnownAs(site).map { registrableDomain($0) }
            let match = candidates.lazy.compactMap { SearchPluginCatalogue.plugin(forDomain: $0) }.first

            guard let plugin = match else { plan.unmatched.append(primary); continue }
            guard !seenPlugins.contains(plugin.id) else { continue }
            seenPlugins.insert(plugin.id)

            if installed.contains(plugin.id) { plan.covered.append(plugin) }
            else { plan.install.append(plugin) }
        }
        return plan
    }
}

/// Talks to qBittorrent's search API.
///
/// Installing is asynchronous on qBittorrent's side: the request returns 200 the
/// moment it is accepted and the plugin is fetched afterwards, so "accepted" is not
/// "installed". The result is read back rather than assumed.
actor SearchPluginClient {
    private let session: URLSession
    private var sid: String?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.httpShouldSetCookies = false
        session = URLSession(configuration: cfg)
    }

    struct Failure: Error { let message: String }

    struct Outcome: Equatable {
        var installed: [String] = []
        var failed: [String] = []
        var unmatched: [String] = []
        var alreadyThere = 0
    }

    /// Engine names qBittorrent currently has.
    func installedNames(base: URL, credentials: QBCredentials) async throws -> Set<String> {
        let data = try await get("api/v2/search/plugins", base: base, credentials: credentials)
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure(message: "qBittorrent's plugin list could not be read")
        }
        return Set(list.compactMap { $0["name"] as? String })
    }

    /// Installs, then reads the list back to see what actually arrived.
    func install(_ plugins: [SearchPluginSource],
                 base: URL, credentials: QBCredentials) async throws -> Outcome {
        guard !plugins.isEmpty else { return Outcome() }
        let sources = plugins.map(\.source).joined(separator: "|")
        _ = try await post("api/v2/search/installPlugin",
                           body: "sources=\(esc(sources))", base: base, credentials: credentials)

        // Fetching happens after the request is answered, so give it a moment and then
        // ask rather than reporting a success the client has not actually had yet.
        var landed = Set<String>()
        for attempt in 0..<6 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 1_500_000_000 : 1_000_000_000)
            landed = (try? await installedNames(base: base, credentials: credentials)) ?? []
            if plugins.allSatisfy({ landed.contains($0.id) }) { break }
        }

        var outcome = Outcome()
        for p in plugins {
            if landed.contains(p.id) { outcome.installed.append(p.site) }
            else { outcome.failed.append(p.site) }
        }
        // A newly installed plugin is enabled by default, but one that was uninstalled
        // and reinstalled is not always, and a disabled plugin is not searched.
        if !outcome.installed.isEmpty {
            let names = plugins.filter { landed.contains($0.id) }.map(\.id).joined(separator: "|")
            _ = try? await post("api/v2/search/enablePlugin",
                                body: "names=\(esc(names))&enable=true",
                                base: base, credentials: credentials)
        }
        return outcome
    }

    // MARK: - Transport

    private func get(_ path: String, base: URL, credentials: QBCredentials) async throws -> Data {
        try await request(path, body: nil, base: base, credentials: credentials)
    }

    private func post(_ path: String, body: String,
                      base: URL, credentials: QBCredentials) async throws -> Data {
        try await request(path, body: body, base: base, credentials: credentials)
    }

    private func request(_ path: String, body: String?,
                         base: URL, credentials: QBCredentials) async throws -> Data {
        if sid == nil { sid = try await login(base: base, credentials: credentials) }
        do {
            return try await send(path, body: body, base: base)
        } catch let e as Failure where e.message == "expired" {
            sid = try await login(base: base, credentials: credentials)
            return try await send(path, body: body, base: base)
        }
    }

    private func send(_ path: String, body: String?, base: URL) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else {
            throw Failure(message: "Bad qBittorrent URL")
        }
        var req = URLRequest(url: url)
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        }
        if let sid { req.setValue("SID=\(sid)", forHTTPHeaderField: "Cookie") }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "No response") }
        if http.statusCode == 403 { throw Failure(message: "expired") }
        // Worth its own message: this is what an older build, or one compiled without
        // the search engine, answers -- and "HTTP 404" would send someone hunting for
        // a typo in the address instead.
        if http.statusCode == 404 {
            throw Failure(message: "This qBittorrent has no search API. "
                          + "It needs version 4.1 or later, built with search support.")
        }
        if http.statusCode == 409 {
            let detail = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty
                          ? "qBittorrent refused the request"
                          : detail)
        }
        guard http.statusCode == 200 else {
            throw Failure(message: "qBittorrent returned HTTP \(http.statusCode)")
        }
        return data
    }

    private func login(base: URL, credentials: QBCredentials) async throws -> String {
        guard let url = URL(string: "api/v2/auth/login", relativeTo: base) else {
            throw Failure(message: "Bad qBittorrent URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("username=\(esc(credentials.username))&password=\(esc(credentials.password))".utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "No response") }
        guard http.statusCode == 200,
              (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Ok")
        else { throw Failure(message: "qBittorrent rejected the sign-in") }

        let fields = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        guard let s = HTTPCookie.cookies(withResponseHeaderFields: fields, for: base)
            .first(where: { $0.name == "SID" })?.value
        else { throw Failure(message: "No session cookie returned") }
        return s
    }

    private func esc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Keeps qBittorrent's search plugins in step with the sites in the bar.
///
/// Add a site, and the plugin for it is installed. That is the whole feature. It runs
/// on launch and whenever the bar changes, so a site added on another machine -- or
/// one added before qBittorrent was configured -- is picked up too.
///
/// Nothing is ever removed. Uninstalling a plugin because a chip was hidden for an
/// afternoon would be a destructive answer to a reversible action, and a plugin that
/// is installed but unused costs nothing.
@MainActor
final class SearchPluginSync: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var lastPlan: SearchPluginPlan?

    private let client = SearchPluginClient()
    private let defaults = UserDefaults.standard
    private var settings: AppSettings { AppSettings.shared }

    /// Site sets already dealt with, so an ordinary launch is silent and free.
    private var signatureKey: String { "qb.plugins.signature" }
    /// Plugins whose install did not take. Retried on the next launch, but not on
    /// every bookmark edit in between -- a dead upstream would otherwise mean a
    /// network round trip every time a chip moved.
    private var failedKey: String { "qb.plugins.failed" }

    func syncIfNeeded(sites: [URL], alsoKnownAs: @escaping (URL) -> [String]) {
        guard settings.syncSearchPlugins else { return }
        let signature = sites.map(\.absoluteString).sorted().joined(separator: "\n")
        guard signature != defaults.string(forKey: signatureKey) else { return }
        run(sites: sites, alsoKnownAs: alsoKnownAs, signature: signature, manual: false)
    }

    func syncNow(sites: [URL], alsoKnownAs: @escaping (URL) -> [String]) {
        let signature = sites.map(\.absoluteString).sorted().joined(separator: "\n")
        defaults.removeObject(forKey: failedKey)
        run(sites: sites, alsoKnownAs: alsoKnownAs, signature: signature, manual: true)
    }

    private func run(sites: [URL], alsoKnownAs: @escaping (URL) -> [String],
                     signature: String, manual: Bool) {
        guard !busy else { return }
        guard let base = settings.qbBase else {
            if manual { status = "No torrent client is configured." }
            return
        }
        guard QBCredentialStore.exists() else {
            if manual { status = "No qBittorrent sign-in is saved." }
            return
        }

        busy = true
        status = "Checking qBittorrent's search plugins\u{2026}"
        QBCredentialStore.withCredentials { [weak self] creds in
            Task { @MainActor in
                guard let self else { return }
                guard let creds else {
                    self.busy = false
                    self.status = "The qBittorrent sign-in could not be read."
                    return
                }
                await self.perform(sites: sites, alsoKnownAs: alsoKnownAs, signature: signature,
                                   manual: manual, base: base, credentials: creds)
            }
        }
    }

    private func perform(sites: [URL], alsoKnownAs: (URL) -> [String], signature: String,
                         manual: Bool, base: URL, credentials: QBCredentials) async {
        defer { busy = false }
        do {
            let installed = try await client.installedNames(base: base, credentials: credentials)
            var plan = SearchPluginPlan.make(sites: sites, installed: installed,
                                             alsoKnownAs: alsoKnownAs)
            lastPlan = plan

            // Something that failed before is not retried on every edit, but a manual
            // sync always tries everything -- that is what the button is for.
            let failed = Set(defaults.stringArray(forKey: failedKey) ?? [])
            if !manual, !failed.isEmpty {
                plan.install.removeAll { failed.contains($0.id) }
            }

            guard !plan.install.isEmpty else {
                defaults.set(signature, forKey: signatureKey)
                status = Self.summary(covered: plan.covered.count, installed: [],
                                      failed: [], unmatched: plan.unmatched)
                return
            }

            status = "Installing \(plan.install.count) search "
                + (plan.install.count == 1 ? "plugin\u{2026}" : "plugins\u{2026}")
            let outcome = try await client.install(plan.install, base: base, credentials: credentials)

            let stillFailing = plan.install.filter { outcome.failed.contains($0.site) }.map(\.id)
            if stillFailing.isEmpty { defaults.removeObject(forKey: failedKey) }
            else { defaults.set(Array(Set(stillFailing).union(failed)), forKey: failedKey) }

            defaults.set(signature, forKey: signatureKey)
            status = Self.summary(covered: plan.covered.count, installed: outcome.installed,
                                  failed: outcome.failed, unmatched: plan.unmatched)
        } catch let e as SearchPluginClient.Failure {
            status = e.message
        } catch {
            status = (error as NSError).localizedDescription
        }
    }

    /// Says what happened, including the part that did not happen. "Sync complete"
    /// over a list of sites that have no plugin would be a lie of omission.
    nonisolated static func summary(covered: Int, installed: [String], failed: [String],
                        unmatched: [String]) -> String {
        var parts: [String] = []
        if !installed.isEmpty { parts.append("Added \(installed.joined(separator: ", "))") }
        if covered > 0 { parts.append("\(covered) already installed") }
        if !failed.isEmpty { parts.append("could not install \(failed.joined(separator: ", "))") }
        if !unmatched.isEmpty {
            let names = unmatched.prefix(3).joined(separator: ", ")
            let rest = unmatched.count > 3 ? " and \(unmatched.count - 3) more" : ""
            parts.append("no published plugin for \(names)\(rest)")
        }
        return parts.isEmpty ? "Nothing to do." : parts.joined(separator: "; ") + "."
    }
}
