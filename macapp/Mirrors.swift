import Foundation

/// A site that publishes several interchangeable domains, in preference order.
struct MirrorSet: Equatable, Codable {
    let id: String
    let name: String
    /// Ordered candidates, the publisher's own preference first.
    var candidates: [URL]
}

/// Where a set's domain list is published, and how to read it.
struct MirrorSource {
    let id: String
    let name: String
    /// Used until the first successful fetch, and if the upstream is unreachable
    /// on a cold install with nothing cached.
    let seed: [String]
    /// Nil when nobody publishes the list and the seed is the whole truth.
    let fetch: (@Sendable () async throws -> [String])?
}


/// Keeps sites' domain lists current from whoever publishes them, and moves off a
/// domain that stops answering.
///
/// Two kinds of set. **Curated** ones have a named upstream and take precedence:
/// Anna's Archive is read from its Wikipedia infobox because those domains rotate
/// under takedown orders, and ExT is a fixed list ordered to avoid a Cloudflare
/// interstitial. **Discovered** ones come from FMHY's published list in bulk, and
/// only fill in hosts a curated set has not already claimed.
@MainActor
final class MirrorDirectory: ObservableObject {
    static let shared = MirrorDirectory()

    @Published private(set) var curated: [String: MirrorSet] = [:]
    @Published private(set) var discovered: [String: MirrorSet] = [:]
    @Published private(set) var status: String = "Mirrors not checked yet"

    /// Announced so the UI can say which domain it moved to.
    var onSwitch: ((String, URL) -> Void)?

    private let defaults = UserDefaults.standard
    private var refreshing = false

    /// Domains get seized, so upstreams are checked far more often than a plain list
    /// of links would justify.
    private static var refreshInterval: TimeInterval {
        AppSettings.shared.mirrorRefreshInterval
    }

    /// Hand-checked sets, from settings. A set naming a Wikipedia article reads its
    /// domain list live from that article's infobox; one without is a fixed list.
    /// Nothing ships by default -- a mirror list is per-site knowledge, not something
    /// to guess at on someone else's behalf.
    private static var sources: [MirrorSource] {
        AppSettings.shared.curatedMirrors.map { entry in
            MirrorSource(
                id: entry.id,
                name: entry.name,
                seed: entry.urls,
                fetch: entry.page.map { page -> @Sendable () async throws -> [String] in
                    { try await WikipediaInfobox.urls(page: page) }
                }
            )
        }
    }

    private init() {
        for source in Self.sources {
            let cached = defaults.stringArray(forKey: "mirrors.cache.\(source.id)")
            let urls = (cached?.isEmpty == false ? cached! : source.seed).compactMap(URL.init(string:))
            curated[source.id] = MirrorSet(id: source.id, name: source.name, candidates: urls)
        }
        discovered = FMHYList.loadCache()
        status = "\(curated.count) curated, \(discovered.count) discovered"
    }

    // MARK: - Lookup

    /// Host to owning set. Curated sets are inserted first and are never displaced,
    /// so a bulk list can add coverage but cannot override a hand-checked ordering.
    private var hostIndex: [String: MirrorSet] {
        var index: [String: MirrorSet] = [:]
        for set in curated.values {
            for url in set.candidates {
                if let host = url.host { index[registrableDomain(host)] = set }
            }
        }
        for set in discovered.values {
            for url in set.candidates {
                guard let host = url.host else { continue }
                let key = registrableDomain(host)
                if index[key] == nil { index[key] = set }
            }
        }
        return index
    }

    func set(owning url: URL) -> MirrorSet? {
        guard let host = url.host else { return nil }
        return hostIndex[registrableDomain(host)]
    }

    /// The remembered replacement for a set, if one was ever chosen.
    ///
    /// Absence means the URL the caller already has is still the right one. A set's
    /// internal ordering must never silently redirect a chip that works -- the
    /// publisher's preferred domain is not necessarily the one the user bookmarked.
    func override(for id: String) -> URL? {
        guard let stored = defaults.string(forKey: "mirrors.active.\(id)"),
              let url = URL(string: stored),
              // A remembered choice that has fallen off the published list is stale.
              allSets[id]?.candidates.contains(where: { $0.host == url.host }) == true
        else { return nil }
        return url
    }

    private var allSets: [String: MirrorSet] { curated.merging(discovered) { a, _ in a } }

    /// Rewrites a URL onto the remembered replacement for its set, keeping the path
    /// so a deep link still lands in the right place.
    func resolve(_ url: URL) -> URL {
        guard let set = set(owning: url),
              let active = override(for: set.id),
              active.host != url.host
        else { return url }
        return rehost(url, onto: active)
    }

    private func rehost(_ original: URL, onto host: URL) -> URL {
        var parts = URLComponents(url: original, resolvingAgainstBaseURL: false)
        parts?.scheme = host.scheme
        parts?.host = host.host
        parts?.port = host.port
        return parts?.url ?? host
    }

    /// Pin a specific domain by hand, from the chip's menu.
    ///
    /// A deliberate choice outranks probing, which is the point: probes run DIRECTLY
    /// from this Mac, so on a proxied route they can only report what this Mac can
    /// see, and that is not what the web view experiences.
    func use(_ url: URL, for id: String) {
        remember(url, for: id)
    }

    /// Back to letting reachability decide.
    func clearOverride(for id: String) {
        forget(id)
    }

    /// Probes every domain in a set. Returns them in the set's own order with whether
    /// each answered, for reporting to the user.
    func survey(_ id: String) async -> [(url: URL, answers: Bool)] {
        guard let set = allSets[id] else { return [] }
        var out: [(URL, Bool)] = []
        for candidate in set.candidates {
            out.append((candidate, await Reachability.answers(candidate)))
        }
        return out
    }

    private func remember(_ url: URL, for id: String) {
        defaults.set(url.absoluteString, forKey: "mirrors.active.\(id)")
        objectWillChange.send()
    }

    private func forget(_ id: String) {
        defaults.removeObject(forKey: "mirrors.active.\(id)")
        objectWillChange.send()
    }

    // MARK: - Failure handling

    /// Called when a navigation failed at the transport layer. Probes the rest of
    /// the set and returns the first domain that answers.
    ///
    /// Returns nil rather than a guess when nothing answers: the caller should leave
    /// the current URL alone, because under the NAS route the web view reaches sites
    /// this Mac cannot probe directly.
    func alternate(for failed: URL) async -> URL? {
        guard let set = set(owning: failed) else { return nil }
        let others = set.candidates.filter { $0.host != failed.host }
        guard !others.isEmpty else { return nil }

        // All at once, in the published order. Probing them one after another cost six
        // seconds per dead domain, and a site rotates domains precisely because the
        // earlier ones stopped answering -- so the serial walk paid the full timeout
        // for every domain that had already gone, before reaching the live one.
        let winner: URL? = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, candidate) in others.enumerated() {
                group.addTask { (index, await Reachability.answers(candidate)) }
            }
            var live: [Int] = []
            for await (index, ok) in group where ok { live.append(index) }
            // The publisher's preferred domain wins, not whichever answered first.
            return live.min().map { others[$0] }
        }
        guard let candidate = winner else { return nil }
        remember(candidate, for: set.id)
        onSwitch?(set.name, candidate)
        return rehost(failed, onto: candidate)
    }

    /// The URL to actually open for a given target: the remembered replacement if
    /// there is one, verified, and a working sibling if not.
    func preferredURL(for url: URL) async -> URL {
        let target = resolve(url)
        if await Reachability.answers(target) { return target }
        // The same host over TLS, before giving up on it. A bookmark saved as plain
        // HTTP is refused by App Transport Security before it reaches the network, and
        // for many of these sites the identical host also answers on https -- so the
        // cheapest alternate is the one already in front of us.
        if target.scheme?.lowercased() == "http",
           var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            if let secure = parts.url, await Reachability.answers(secure) { return secure }
        }
        return await alternate(for: target) ?? target
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        for source in Self.sources {
            if let fetch = source.fetch, due("mirrors.fetched.\(source.id)", force: force) {
                do {
                    let fetched = try await fetch()
                    let urls = fetched.compactMap(URL.init(string:))
                    guard !urls.isEmpty else { throw MirrorError.emptyUpstream }
                    curated[source.id] = MirrorSet(id: source.id, name: source.name, candidates: urls)
                    defaults.set(fetched, forKey: "mirrors.cache.\(source.id)")
                    stamp("mirrors.fetched.\(source.id)")
                } catch {
                    // Cache or seed stays in force. An unreachable upstream must
                    // never leave the app with fewer options than it started with.
                    status = "\(source.name): using cached list (\(error.localizedDescription))"
                }
            }
            await reviewOverride(source.id)
        }

        if AppSettings.shared.fmhyEnabled, due("mirrors.fetched.fmhy", force: force) {
            do {
                let groups = try await FMHYList.fetch()
                if !groups.isEmpty {
                    discovered = groups
                    FMHYList.saveCache(groups)
                    stamp("mirrors.fetched.fmhy")
                }
            } catch {
                status = "FMHY: using cached list (\(error.localizedDescription))"
            }
        }
        for id in discovered.keys { await reviewOverride(id) }

        status = "\(curated.count) curated, \(discovered.count) discovered"
    }

    private func due(_ key: String, force: Bool) -> Bool {
        if force { return true }
        let last = defaults.double(forKey: key)
        return last <= 0 || Date().timeIntervalSince1970 - last >= Self.refreshInterval
    }

    private func stamp(_ key: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    /// Drops an override once the publisher's preferred domain answers again, so a
    /// site that recovers goes back to where it belongs instead of staying parked
    /// on a mirror forever.
    private func reviewOverride(_ id: String) async {
        guard let set = allSets[id],
              let active = override(for: id),
              let original = set.candidates.first,
              original.host != active.host
        else { return }
        if await Reachability.answers(original) { forget(id) }
    }
}

enum MirrorError: LocalizedError {
    case emptyUpstream
    case badResponse

    var errorDescription: String? {
        switch self {
        case .emptyUpstream: return "the published list was empty"
        case .badResponse: return "the response could not be read"
        }
    }
}

// MARK: - Reachability

/// Which failures mean "this domain cannot be reached", as opposed to the site
/// answering with something unwelcome.
///
/// Only these justify moving to another domain: an HTTP-level rejection -- a
/// Cloudflare 403 above all -- still proves the domain is alive, and switching away
/// from it would be wrong.
enum WebFailure {
    static let transport: Set<Int> = [
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorTimedOut,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorNetworkConnectionLost,
        // A plain-HTTP site refused by App Transport Security. The request never
        // leaves the process, so the domain is unreachable AS WRITTEN -- precisely
        // what another domain is for.
        NSURLErrorAppTransportSecurityRequiresSecureConnection,
    ]

    static func isTransport(_ code: Int) -> Bool { transport.contains(code) }
}

enum Reachability {
    /// Reachability, not success -- the same rule the route probe uses. A Cloudflare
    /// challenge is a 403 and still proves the domain is alive; only a transport
    /// failure means it is not.
    static func answers(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 6
        do {
            // Through the proxy, because that is the only way the app reaches sites.
            // Probing directly asked a question about a network nobody browses on.
            _ = try await ProxyRoute.session().data(for: req)
            return true
        } catch {
            return (error as NSError).domain != NSURLErrorDomain
        }
    }
}

// MARK: - FMHY

/// Reads mirror groups out of FMHY's published single-page list.
enum FMHYList {
    static let endpoint = URL(string: "https://api.fmhy.net/single-page")!

    static func fetch() async throws -> [String: MirrorSet] {
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 30
        let (data, _) = try await ProxyRoute.session(timeout: 20).data(for: req)
        guard let text = String(data: data, encoding: .utf8) else { throw MirrorError.badResponse }
        return parse(text)
    }

    /// A line lists one or more sites. A link labelled with a bare number (or
    /// "Proxy") is an alternate of the NEAREST PRECEDING NAMED LINK, not of the
    /// first link on the line -- lines routinely carry several unrelated sites, so
    /// treating every numbered link as a mirror of the first would wire unrelated
    /// domains together and switch to the wrong site.
    static func parse(_ markdown: String) -> [String: MirrorSet] {
        let linkPattern = try! NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\((https?://[^)\\s]+)\\)")
        var groups: [(name: String, urls: [URL])] = []

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*") || trimmed.hasPrefix("-") else { continue }

            var current: Int? = nil
            let range = NSRange(line.startIndex..., in: line)
            for match in linkPattern.matches(in: line, range: range) {
                guard let labelRange = Range(match.range(at: 1), in: line),
                      let urlRange = Range(match.range(at: 2), in: line),
                      let url = URL(string: String(line[urlRange])),
                      url.host != nil
                else { continue }

                let label = String(line[labelRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "* ").union(.whitespaces))
                let isAlternate = !label.isEmpty
                    && (label.allSatisfy(\.isNumber) || label.lowercased() == "proxy")

                if isAlternate {
                    if let i = current { groups[i].urls.append(url) }
                } else {
                    groups.append((name: label, urls: [url]))
                    current = groups.count - 1
                }
            }
        }

        // Only a group spanning two or more real domains offers anything.
        var bySignature: [Set<String>: (name: String, urls: [URL])] = [:]
        for group in groups {
            let domains = Set(group.urls.compactMap { $0.host.map(registrableDomain) })
            guard domains.count >= 2 else { continue }
            // The same site is listed in several sections; identical groups are
            // duplicates, not conflicts.
            if bySignature[domains] == nil { bySignature[domains] = group }
        }

        // A domain claimed by two genuinely different groups is ambiguous, and
        // guessing would switch the user to an unrelated site. Drop those.
        var claims: [String: Int] = [:]
        for (domains, _) in bySignature {
            for d in domains { claims[d, default: 0] += 1 }
        }

        var out: [String: MirrorSet] = [:]
        for (domains, group) in bySignature {
            guard domains.allSatisfy({ claims[$0] == 1 }) else { continue }
            guard let primary = group.urls.first?.host.map(registrableDomain) else { continue }
            let id = "fmhy:" + primary
            out[id] = MirrorSet(id: id,
                                name: group.name.isEmpty ? primary : group.name,
                                candidates: dedupe(group.urls))
        }
        return out
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    // MARK: Cache

    private static var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("1337x", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mirrors-fmhy.json")
    }

    static func saveCache(_ sets: [String: MirrorSet]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(sets) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadCache() -> [String: MirrorSet] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: MirrorSet].self, from: data)) ?? [:]
    }
}

// MARK: - Wikipedia

/// Reads a domain list straight out of an article's infobox.
enum WikipediaInfobox {
    static func urls(page: String) async throws -> [String] {
        var parts = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        parts.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "prop", value: "revisions"),
            .init(name: "rvprop", value: "content"),
            .init(name: "rvslots", value: "main"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
            .init(name: "redirects", value: "1"),
            .init(name: "titles", value: page),
        ]
        var req = URLRequest(url: parts.url!)
        // Wikimedia asks clients to identify themselves; nothing personal in it.
        req.setValue("Magnet/1.0 (macOS; mirror list updater)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, _) = try await ProxyRoute.session(timeout: 20).data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let first = pages.first,
              let revisions = first["revisions"] as? [[String: Any]],
              let slots = revisions.first?["slots"] as? [String: Any],
              let main = slots["main"] as? [String: Any],
              let wikitext = main["content"] as? String
        else { throw MirrorError.badResponse }

        return parseURLTemplates(in: infoboxField(named: "url", of: wikitext) ?? "")
    }

    /// The balanced value of one infobox parameter.
    ///
    /// Scoping to the field matters: it also carries `<ref>` citations, so anything
    /// looser hands back the cited news sites as though they were the subject's own
    /// domains.
    static func infoboxField(named name: String, of wikitext: String) -> String? {
        let chars = Array(wikitext)
        guard let head = wikitext.range(of: "\n\\|\\s*\(name)\\s*=", options: .regularExpression) else { return nil }
        var i = wikitext.distance(from: wikitext.startIndex, to: head.upperBound)
        let start = i
        var depth = 0

        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "{", chars[i + 1] == "{" { depth += 1; i += 2; continue }
            if i + 1 < chars.count, chars[i] == "}", chars[i + 1] == "}" {
                depth -= 1; i += 2
                if depth <= 0 { return String(chars[start..<i]) }
                continue
            }
            // A new parameter at depth 0 ends this one.
            if chars[i] == "\n", depth == 0 {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == "|" { return String(chars[start..<i]) }
            }
            i += 1
        }
        return String(chars[start...])
    }

    /// Only `{{URL|...}}` templates count as a published domain.
    static func parseURLTemplates(in field: String) -> [String] {
        let pattern = "\\{\\{\\s*URL\\s*\\|\\s*(?:1\\s*=\\s*)?([^}|]+?)\\s*\\}\\}"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(field.startIndex..., in: field)
        var out: [String] = []
        for match in re.matches(in: field, range: range) {
            guard let r = Range(match.range(at: 1), in: field) else { continue }
            let raw = String(field[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalised = raw.hasPrefix("http") ? raw : "https://" + raw
            if let url = URL(string: normalised), url.host != nil, !out.contains(normalised) {
                out.append(normalised)
            }
        }
        return out
    }
}
