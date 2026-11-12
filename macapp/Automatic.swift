import Foundation
import SwiftUI

// Automatic mode: new TV episodes found, checked and downloaded on their own.
//
// Nothing here decides anything. The NAS service in nas/automatic does the work --
// Sonarr finds the episode, a gate in front of the seedbox's qBittorrent reads every
// release's file list before a byte of it downloads, a scout hunts for a better copy,
// and each finished episode is copied into its show's season folder and then leaves the
// seedbox. This side shows what the NAS knows and has done, sends it the occasional
// button press (pause, search now, a show's quality), tells you when an episode is in
// Plex, and tells it which sites to search: the same list of sites as the bar, so
// adding a site to Magnet is how a source is added.

// MARK: - What the NAS sends

struct AutoShow: Codable, Hashable {
    let id: Int?
    let tvdbId: Int?
    let title: String
    let year: Int?
    let status: String?
    let network: String?
    let monitored: Bool?
    let nextAiring: String?
    let previousAiring: String?
    let poster: String?
    let overview: String?
    let path: String?
    let magnetProfile: Bool?
    /// Magnet's level for the show: "first", "4k" or "dv"; nil on any other profile.
    let quality: String?
    let inSonarr: Bool?        // search results
    let following: Bool?       // search results
    let why: String?           // suggestions

    var stableID: String { tvdbId.map { "tvdb\($0)" } ?? id.map { "s\($0)" } ?? title }
    var nextDate: Date? { nextAiring.flatMap(AutoDate.parse) }

    func marked(following: Bool) -> AutoShow {
        AutoShow(id: id, tvdbId: tvdbId, title: title, year: year, status: status, network: network,
                 monitored: monitored, nextAiring: nextAiring, previousAiring: previousAiring, poster: poster,
                 overview: overview, path: path, magnetProfile: magnetProfile, quality: quality, inSonarr: true,
                 following: following, why: why)
    }
}

struct AutoEpisode: Codable, Hashable, Identifiable {
    /// Sonarr's episode id; older NAS versions do not send it.
    let episodeId: Int?
    let seriesId: Int
    let series: String?
    let season: Int?
    let episode: Int?
    let title: String?
    let airDateUtc: String?
    let hasFile: Bool
    let monitored: Bool

    var id: String { "\(seriesId)-\(season ?? -1)-\(episode ?? -1)" }
    var airDate: Date? { airDateUtc.flatMap(AutoDate.parse) }
    var code: String { AutoFormat.code(season, episode) }

    enum CodingKeys: String, CodingKey {
        case episodeId = "id", seriesId, series, season, episode, title, airDateUtc, hasFile, monitored
    }
}

/// One thing Automatic did, tied to its show and episode where it has one.
struct AutoActivity: Codable, Hashable, Identifiable {
    let id: Int
    let at: String?
    let kind: String
    let hash: String?
    let message: String
    let detail: String
    let subject: String?
    let seriesId: Int?
    let series: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let formats: [String]?
    let upgrade: Bool?

    var date: Date? { at.flatMap(AutoDate.parse) }
    var badges: [AutoBadge] { AutoBadge.from(formats ?? []) }
    var code: String? { episode == nil ? (season.map { String(format: "S%02d", $0) }) : AutoFormat.code(season, episode) }

    enum Category { case library, downloading, refused, problem, control }

    var category: Category {
        switch kind {
        case "transferred", "imported", "kept", "settled", "season", "matched": return .library
        case "match":
            let d = detail.lowercased()
            return d.contains("gave up") || d.contains("could not") ? .problem : .downloading
        case "rejected", "blocklisted", "stalled", "superseded": return kind == "superseded" ? .library : .refused
        case "stuck", "unreadable", "waiting": return .problem
        case "transfer":
            let d = detail.lowercased()
            return d.contains("could not") || d.contains("without importing") || d.contains("tba") ? .problem : .downloading
        case "follow", "unfollow", "quality", "paused", "resumed", "login": return .control
        default: return .downloading
        }
    }

    /// The event in plain words, without the release name it is about.
    var text: String {
        // "verdict -- reason" is how a decision is written; the reason is what matters.
        let reason = detail.range(of: " -- ").map { String(detail[$0.upperBound...]) }
        switch kind {
        case "held": return "Found a release; checking its files"
        case "approved": return "Passed the check; downloading"
        case "rejected": return "Refused: " + (reason ?? detail)
        case "blocklisted": return "Blocklisted in Sonarr, which takes the next best"
        case "stalled": return "Dropped: " + (reason ?? detail)
        case "superseded": return "Removed from the seedbox: a better copy finished"
        case "imported":
            return (reason ?? "").contains("as good")
                ? "Left the seedbox: the library's copy is as good"
                : "Left the seedbox once it was in the library"
        case "transferred": return upgrade == true ? "Upgraded in the library" : "In the library"
        case "transfer": return detail.prefix(1).uppercased() + detail.dropFirst()
        case "kept": return "Library copy kept: " + detail
        case "quality": return "New episodes: " + detail
        case "match" where detail.hasPrefix("taking ") && detail.hasSuffix(")"):
            // "taking <release> to match the season (WEB 1080p H.264)"
            let open = detail.lastIndex(of: "(").map { detail.index(after: $0) } ?? detail.endIndex
            return "Taking a \(detail[open..<detail.index(before: detail.endIndex)]) copy to match the season"
        case "paused" where subject == nil: return "Automatic paused"
        case "paused": return "Waiting for Automatic to be resumed"
        case "waiting": return "Waiting for space on the seedbox"
        default:
            let text = reason ?? detail
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }
}

struct AutoAttention: Codable, Hashable, Identifiable {
    let key: String
    let title: String
    let detail: String
    var id: String { key }
}

struct AutoActivityFeed: Codable {
    let events: [AutoActivity]
    let latest: Int
    let attention: [AutoAttention]
}

struct AutoEpisodeFile: Codable, Hashable {
    let quality: String?
    let formats: [String]?
    let score: Int?
    let size: Int64?
    let path: String?
    var badges: [AutoBadge] { AutoBadge.from(formats ?? []) }
}

struct AutoShowEpisode: Codable, Hashable, Identifiable {
    let id: Int
    let season: Int?
    let episode: Int?
    let title: String?
    let airDateUtc: String?
    let monitored: Bool
    let hasFile: Bool
    let file: AutoEpisodeFile?
    let betterUntil: String?
    /// What the library's file is, as matching reads it ("WEB 1080p H.264"), and whether
    /// that is the season's main format ("match") or not ("off").
    let format: String?
    let formatState: String?
    /// A copy in the season's format is on its way.
    let matching: Bool?

    var airDate: Date? { airDateUtc.flatMap(AutoDate.parse) }
    var aired: Bool { airDate.map { $0 < Date() } ?? false }
    var code: String { AutoFormat.code(season, episode) }
    var lookingUntil: Date? { betterUntil.flatMap(AutoDate.parse) }
}

struct AutoSeason: Codable, Hashable, Identifiable {
    let season: Int
    let episodes: [AutoShowEpisode]
    let match: AutoSeasonFormats?
    var id: Int { season }
    var title: String { season == 0 ? "Specials" : "Season \(season)" }

    /// The episodes in the library that are not in `target`, nor on their way to it.
    func notIn(_ target: String) -> [AutoShowEpisode] {
        episodes.filter { $0.hasFile && $0.format != nil && $0.format != target && $0.matching != true }
    }
    var beingMatched: [AutoShowEpisode] { episodes.filter { $0.matching == true } }
}

/// One format a season's files are in, and the median size of an episode in it.
struct AutoFormatGroup: Codable, Hashable {
    let label: String
    let episodes: [Int?]
    let size: Int64
    var numbers: [Int] { episodes.compactMap { $0 } }
}

/// A season's formats, biggest first; `target` is the biggest's.
struct AutoSeasonFormats: Codable, Hashable {
    let target: String?
    let groups: [AutoFormatGroup]
}

struct AutoSeasonMatch: Codable {
    let started: Int
    let target: String?
    let message: String
}

struct AutoLevel: Codable, Hashable, Identifiable {
    let id: String
    let title: String
}

struct AutoShowDetail: Codable {
    let show: AutoShow
    let profile: String?
    let levels: [AutoLevel]
    let seasons: [AutoSeason]
    let seedbox: [AutoTorrent]
    let activity: [AutoActivity]
    let paused: Bool
}

struct AutoSearchNow: Codable {
    let taken: String?
    let message: String
}

struct AutoTorrent: Codable, Hashable, Identifiable {
    let hash: String
    let name: String?
    let state: String?
    let progress: Double?
    let size: Int64?
    let dlspeed: Int64?
    let eta: Int64?
    let addedOn: String?
    let completedOn: String?
    let verdict: String
    let reason: String?
    let series: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let transferring: Bool
    let onNAS: Bool
    let score: Int?
    let formats: [String]?
    let betterUntil: String?
    // qBittorrent's own reading: the word its list shows, and whether it is done.
    let stateLabel: String?
    let progressText: String?
    let finished: Bool?
    let checking: Bool?
    /// The copy to the NAS, for a finished episode: waiting (the NAS copies it by
    /// itself), running, done, skipped (Sonarr kept the library's copy), or failed (the
    /// automatic copy gave up). Older NAS versions do not say.
    let copyStatus: String?
    let copyMessage: String?

    var id: String { hash }
    var lookingUntil: Date? { betterUntil.flatMap(AutoDate.parse) }
    var badges: [AutoBadge] { AutoBadge.from(formats ?? []) }
    /// Finished the way qBittorrent shows it: every byte there and no check running.
    /// Older NAS versions do not say, so fall back to the progress figure.
    var isComplete: Bool { finished ?? ((progress ?? 0) >= 1) }
    /// Only where pressing it does something the NAS will not do by itself: when the
    /// automatic copy has given up, or on a NAS that never copies by itself.
    var canBringToNAS: Bool {
        verdict == "approved" && isComplete && checking != true && !transferring && !onNAS
            && (copyStatus == nil || copyStatus == "failed")
    }
}

struct AutoSeedbox: Codable, Hashable {
    let torrents: [AutoTorrent]
    let freeBytes: Int64?
    let minFreeBytes: Int64?
    /// Whether the NAS copies finished episodes by itself.
    let autoCopy: Bool?
    /// Whether a copy that reached the NAS leaves the seedbox, torrent and files.
    let removeAfterCopy: Bool?
}

struct AutoBlocked: Codable, Hashable, Identifiable {
    let hash: String
    let name: String
    let reason: String
    let files: [String]
    let at: String?
    let blocklisted: Bool
    let telling: Bool?
    var id: String { hash }
}

struct AutoTransfer: Codable, Hashable, Identifiable {
    let id: Int
    let hash: String
    let name: String
    let status: String
    let message: String
    let created: Double
    let updated: Double
}

struct AutoHealth: Codable, Hashable {
    let seedboxLogin: Bool
    let seedboxBlocked: Bool
    let seedboxError: String?
    let streaming: Bool?
    let lastPoll: String?
    let sonarr: Bool
    let sonarrError: String?
    let freeBytes: Int64?
}

/// One site from the bar, as the NAS sees it: a name and every domain it goes by.
struct AutoSite: Codable, Hashable {
    let name: String
    let domains: [String]
}

/// What the NAS made of one site: searched for episodes, or why not.
struct AutoCoverage: Codable, Hashable, Identifiable {
    let site: String
    let domains: [String]?
    let status: String          // searching | no-tv | unsupported | private | failed
    let detail: String?
    let indexer: String?
    var id: String { site }

    var searched: Bool { status == "searching" }
    var explanation: String {
        switch status {
        case "searching": return "Searched for new episodes" + (indexer.map { " (\($0))" } ?? "")
        case "no-tv": return "No TV on this site"
        case "unsupported": return "No indexer exists for this site"
        case "private": return "Needs an account"
        case "disabled": return "Turned off in Prowlarr"
        case "failed": return "Could not be added: " + (detail ?? "unknown error")
        default: return detail ?? status
        }
    }
}

/// What makes a copy good, in a few words, from the custom formats Sonarr matched.
struct AutoBadge: Hashable {
    let text: String
    let isDV: Bool

    static func from(_ formats: [String]) -> [AutoBadge] {
        let f = Set(formats)
        var out: [AutoBadge] = []
        if f.contains("DV Boost") { out.append(AutoBadge(text: "Dolby Vision", isDV: true)) }
        if f.contains("HDR10+ Boost") { out.append(AutoBadge(text: "HDR10+", isDV: false)) }
        else if f.contains("HDR") && !f.contains("DV Boost") { out.append(AutoBadge(text: "HDR", isDV: false)) }
        if f.contains("2160p") { out.append(AutoBadge(text: "4K", isDV: false)) }
        else if f.contains("1080p") { out.append(AutoBadge(text: "1080p", isDV: false)) }
        if let a = ["TrueHD ATMOS", "DD+ ATMOS", "ATMOS (undefined)"].first(where: f.contains) {
            out.append(AutoBadge(text: a == "TrueHD ATMOS" ? "TrueHD Atmos" : "Atmos", isDV: false))
        } else if f.contains("DTS X") { out.append(AutoBadge(text: "DTS:X", isDV: false)) }
        else if f.contains("TrueHD") { out.append(AutoBadge(text: "TrueHD", isDV: false)) }
        if f.contains("Remux Tier 01") || f.contains("Remux Tier 02") { out.append(AutoBadge(text: "Top remux group", isDV: false)) }
        else if f.contains("WEB Tier 01") || f.contains("WEB Tier 02") { out.append(AutoBadge(text: "Top web group", isDV: false)) }
        return out
    }
}

struct AutoScoutStatus: Codable, Hashable {
    let lastRun: String?
    let lookingForBetter: Int
    let settled: Int
    let windowDays: Int
    let error: String?
    let nextClose: String?
}

struct AutoSourcesStatus: Codable, Hashable {
    let sites: [AutoSite]
    let coverage: [AutoCoverage]
    let appliedAt: String?
    let pending: Bool
    let error: String?
}

struct AutoOverview: Codable {
    let version: String
    /// Older NAS versions do not say.
    let paused: Bool?
    let following: [AutoShow]
    let upcoming: [AutoEpisode]
    let seedbox: AutoSeedbox
    let blocked: [AutoBlocked]
    let transfers: [AutoTransfer]
    let health: AutoHealth
    let sources: AutoSourcesStatus?
    let scout: AutoScoutStatus?
}

private struct AutoAPIError: Codable { let error: String }

enum AutoDate {
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parse(_ s: String) -> Date? { plain.date(from: s) ?? fractional.date(from: s) }
}

enum AutoFormat {
    static func code(_ season: Int?, _ episode: Int?) -> String {
        guard let s = season, let e = episode else { return "" }
        return String(format: "S%02dE%02d", s, e)
    }

    static func bytes(_ n: Int64?) -> String {
        guard let n else { return "" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func eta(_ seconds: Int64?) -> String? {
        guard let s = seconds, s > 0, s < 8_640_000 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(s))
    }

    static func airTime(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Talking to the NAS

struct AutoClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The API token is a file, not a Keychain item. `nas/automatic/deploy.sh --token`
/// writes it (mode 600), and Settings can too. A Keychain item created by another
/// tool would make macOS ask before Magnet could read it -- a dialog over whatever
/// is on screen, at whatever moment the first poll happens.
enum AutoToken {
    nonisolated static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(AppSettings.appName)/automatic-token")
    }

    nonisolated static var value: String? {
        let s = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    nonisolated static func save(_ token: String) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard FileManager.default.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw AutoClientError(message: "Could not write \(file.path)")
        }
    }
}

struct AutoClient: Sendable {
    let base: URL
    let token: String

    /// nil until both an address and a token exist.
    static func current() -> AutoClient? {
        guard let base = Config.automaticBase, let token = AutoToken.value else { return nil }
        return AutoClient(base: base, token: token)
    }

    // Unproxied, like the qBittorrent client: this is a NAS on the LAN or tailnet, and
    // the CONNECT proxy only tunnels to ports 443 and 563.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            // Leaving a pane or closing Settings cancels its request; that is not an error.
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw AutoClientError(message: "The NAS did not answer in time.")
        } catch let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection {
            throw AutoClientError(message: "macOS refused plain HTTP to \(base.host ?? "the NAS"). Add it to MAGNET_HTTP_HOSTS in local.env and rebuild.")
        } catch let e as URLError {
            throw AutoClientError(message: "Cannot reach the NAS at \(base.host ?? base.absoluteString) (\(e.localizedDescription)).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let err = try? JSONDecoder().decode(AutoAPIError.self, from: data) {
                throw AutoClientError(message: err.error)
            }
            throw AutoClientError(message: status == 401 ? "The NAS refused the API token." : "The NAS answered \(status).")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func overview() async throws -> AutoOverview { try decode(AutoOverview.self, await request("GET", "v1/overview")) }

    func search(_ term: String) async throws -> [AutoShow] {
        try decode([AutoShow].self, await request("GET", "v1/search", query: [.init(name: "term", value: term)]))
    }

    func suggestions(picks: [String]) async throws -> [AutoShow] {
        try decode([AutoShow].self, await request("POST", "v1/suggestions", body: ["picks": picks], timeout: 120))
    }

    func follow(tvdbId: Int) async throws -> AutoShow {
        try decode(AutoShow.self, await request("POST", "v1/follow", body: ["tvdbId": tvdbId], timeout: 90))
    }

    func unfollow(id: Int) async throws { _ = try await request("POST", "v1/unfollow", body: ["id": id]) }

    func bringToNAS(hash: String) async throws { _ = try await request("POST", "v1/transfer", body: ["hash": hash]) }

    func seedboxLogin(username: String, password: String) async throws {
        _ = try await request("POST", "v1/seedbox-login", body: ["username": username, "password": password])
    }

    func sources() async throws -> AutoSourcesStatus {
        try decode(AutoSourcesStatus.self, await request("GET", "v1/sources"))
    }

    func activity(since: Int = 0, limit: Int = 300) async throws -> AutoActivityFeed {
        try decode(AutoActivityFeed.self, await request("GET", "v1/activity", query: [
            .init(name: "since", value: String(since)), .init(name: "limit", value: String(limit))], timeout: 60))
    }

    func show(id: Int) async throws -> AutoShowDetail {
        try decode(AutoShowDetail.self, await request("GET", "v1/show", query: [.init(name: "id", value: String(id))],
                                                      timeout: 60))
    }

    func setPaused(_ paused: Bool) async throws { _ = try await request("POST", "v1/pause", body: ["paused": paused]) }

    /// Searches the indexers there and then, so it can take a while.
    func searchNow(episodeId: Int) async throws -> AutoSearchNow {
        try decode(AutoSearchNow.self, await request("POST", "v1/search-now", body: ["episodeId": episodeId],
                                                     timeout: 300))
    }

    /// Starts matching a season on the NAS. The searches run there afterwards.
    func seasonMatch(seriesId: Int, season: Int, target: String?) async throws -> AutoSeasonMatch {
        var body: [String: Any] = ["seriesId": seriesId, "season": season]
        if let target { body["target"] = target }
        return try decode(AutoSeasonMatch.self, await request("POST", "v1/season-match", body: body, timeout: 120))
    }

    func setQuality(seriesId: Int, level: String) async throws -> AutoShow {
        try decode(AutoShow.self, await request("POST", "v1/show-quality", body: ["id": seriesId, "level": level],
                                                timeout: 60))
    }

    func setSources(_ sites: [AutoSite]) async throws -> AutoSourcesStatus {
        let body: [String: Any] = ["sites": sites.map { ["name": $0.name, "domains": $0.domains] }]
        return try decode(AutoSourcesStatus.self, await request("POST", "v1/sources", body: body))
    }
}

// MARK: - The sites decide the sources

enum AutoSources {
    /// The bar's sites as the NAS needs them: each site's name and every domain it is
    /// known by, mirrors included, so a site Magnet reaches at this month's mirror is
    /// matched to an indexer that lists last month's. The home site counts, the same
    /// as for search plugins.
    @MainActor
    static func sites(from bookmarks: [Bookmark], home: URL?,
                      alsoKnownAs: @MainActor (URL) -> [String] = AutoSources.mirrorHosts) -> [AutoSite] {
        var out: [AutoSite] = []
        var seen = Set<String>()
        for bm in Bookmark.withHome(bookmarks, home: home) {
            guard let host = bm.url.host?.lowercased(), SearchPluginPlan.isSearchableSite(host) else { continue }
            let primary = registrableDomain(host)
            guard seen.insert(primary).inserted else { continue }
            var domains = [host]
            for alt in alsoKnownAs(bm.url).map({ $0.lowercased() }) where !domains.contains(alt) {
                domains.append(alt)
            }
            let name = MirrorDirectory.shared.set(owning: bm.url)?.name
                ?? (bm.title == Bookmark.homeTitle ? primary : bm.chipLabel)
            // Two chips at two mirrors of one site are one site: merge them, so the
            // NAS (and the coverage list, which is keyed by name) sees it once.
            if let i = out.firstIndex(where: { $0.name == name }) {
                out[i] = AutoSite(name: name, domains: out[i].domains + domains.filter { !out[i].domains.contains($0) })
            } else {
                out.append(AutoSite(name: name, domains: domains))
            }
        }
        return out
    }

    /// Every host a site's mirror set lists (the same lookup search-plugin sync uses).
    @MainActor
    static func mirrorHosts(_ url: URL) -> [String] {
        MirrorDirectory.shared.set(owning: url)?.candidates.compactMap(\.host) ?? []
    }

    /// A one-way fingerprint (FNV-1a), so a stored signature can tell tokens apart
    /// without keeping any part of one.
    static func digest(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// Order-independent, so reordering or pinning chips does not resend the list.
    static func signature(_ sites: [AutoSite]) -> String {
        sites.map { $0.name + "=" + $0.domains.sorted().joined(separator: ",") }.sorted().joined(separator: "\n")
    }
}

/// Keeps the NAS's list of sources equal to the bar, the way SearchPluginSync keeps
/// qBittorrent's plugins equal to it. The signature is stored only after the NAS has
/// accepted the list, so a failure is retried on the next trigger.
@MainActor
final class AutoSourceSync: ObservableObject {
    @Published private(set) var status: AutoSourcesStatus?
    @Published private(set) var message = ""
    @Published private(set) var busy = false

    private let key = "automatic.sources.signature"
    /// A list asked for while another was being sent. Kept, never dropped: the newest
    /// request is the one that has to arrive.
    private var queued: [AutoSite]?

    /// What was accepted, by which server, under which token -- so pointing Magnet at
    /// another NAS (or a freshly deployed one) sends the list again.
    private func signature(_ sites: [AutoSite], _ client: AutoClient) -> String {
        AutoSources.signature(sites) + "@" + client.base.absoluteString + "#" + AutoSources.digest(client.token)
    }

    func syncIfNeeded(_ sites: [AutoSite]) {
        guard !sites.isEmpty, let client = AutoClient.current() else { return }
        guard busy || UserDefaults.standard.string(forKey: key) != signature(sites, client) else { return }
        Task { await perform(sites) }
    }

    func syncNow(_ sites: [AutoSite]) {
        Task { await perform(sites) }
    }

    func refresh() async {
        guard let client = AutoClient.current() else { status = nil; return }
        if let s = try? await client.sources(), AutoClient.current()?.base == client.base { status = s }
    }

    /// The address or token changed: what was shown belonged to the old one.
    func serverChanged() {
        status = nil
        message = ""
    }

    /// The NAS no longer holds the list Magnet last sent it (a redeploy that lost its
    /// data, say): forget that it was sent, so the next sync sends it again.
    func reconcile(remote: [AutoSite]?, local: [AutoSite]) {
        guard let remote, Set(remote.map(\.name)) != Set(local.map(\.name)) else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func perform(_ sites: [AutoSite]) async {
        guard !busy else {
            queued = sites
            return
        }
        guard let client = AutoClient.current() else {
            message = "Set the NAS address and API token first."
            return
        }
        guard !sites.isEmpty else {
            // Never sent: an empty list would leave Sonarr with nothing to search.
            message = "There are no sites in the bar to search."
            return
        }
        busy = true
        let attempted = signature(sites, client)
        // A reply is only kept while the address and token are still the ones it was
        // sent with; typing a new address mid-send makes it someone else's answer.
        func current() -> Bool {
            AutoClient.current().map { $0.base == client.base && $0.token == client.token } ?? false
        }
        do {
            let st = try await client.setSources(sites)
            if current() {
                status = st
                UserDefaults.standard.set(attempted, forKey: key)
                message = ""
            }
        } catch is CancellationError {
        } catch {
            if current() { message = error.localizedDescription }
        }
        busy = false
        // A newer request that arrived meanwhile goes out if it differs from this one in
        // its sites OR its destination.
        if let next = queued {
            queued = nil
            if let now = AutoClient.current(), signature(next, now) != attempted { await perform(next) }
        }
    }
}

// MARK: - State behind Automatic mode

enum AutoPane: String, CaseIterable, Identifiable {
    case following, upcoming, activity, seedbox, blocked, suggestions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .following: return "Following"
        case .upcoming: return "Coming Up"
        case .activity: return "Activity"
        case .seedbox: return "Seedbox"
        case .blocked: return "Blocked"
        case .suggestions: return "Suggestions"
        }
    }

    var symbol: String {
        switch self {
        case .following: return "tv"
        case .upcoming: return "calendar"
        case .activity: return "list.bullet.rectangle"
        case .seedbox: return "arrow.down.circle"
        case .blocked: return "hand.raised"
        case .suggestions: return "sparkles.tv"
        }
    }
}

@MainActor
final class AutomaticModel: ObservableObject {
    @Published var overview: AutoOverview?
    @Published var error: String?
    @Published var loading = false
    @Published var lastRefresh: Date?
    @Published var pane: AutoPane = .following

    @Published var suggestions: [AutoShow] = []
    @Published var suggestionsLoaded = false
    @Published var suggestionsLoading = false
    @Published var suggestionsError: String?

    @Published var searchResults: [AutoShow] = []
    @Published var searching = false
    @Published var searchError: String?

    @Published var busy: Set<String> = []
    @Published var notice: String?

    @Published var activity: AutoActivityFeed?
    @Published var activityError: String?
    /// What needs a person, from the last look at the NAS's activity.
    @Published var attention: [AutoAttention] = []

    /// The show whose page is open, over whichever pane was showing.
    @Published var openShowID: Int?
    @Published var showDetail: AutoShowDetail?
    @Published var showError: String?

    private var poller: Task<Void, Never>?
    private var wantActive = false
    private var visible = true

    var health: AutoHealth? { overview?.health }
    var paused: Bool { overview?.paused == true }
    var configured: Bool { AutoClient.current() != nil }
    var needsSeedboxLogin: Bool { health.map { !$0.seedboxLogin || $0.seedboxBlocked } ?? false }

    func count(_ pane: AutoPane) -> Int? {
        guard let o = overview else { return nil }
        switch pane {
        case .following: return o.following.isEmpty ? nil : o.following.count
        case .upcoming: return nil
        case .activity: return attention.isEmpty ? nil : attention.count
        case .seedbox:
            let ready = o.seedbox.torrents.filter(\.canBringToNAS).count
            return ready > 0 ? ready : nil
        case .blocked: return o.blocked.isEmpty ? nil : o.blocked.count
        case .suggestions: return suggestionsLoaded && !suggestions.isEmpty ? suggestions.count : nil
        }
    }

    /// Polls only while Automatic mode is showing in a window that can be seen: not in
    /// Manual mode, not minimized, not hidden, not on another Space.
    func setActive(_ active: Bool) {
        wantActive = active
        apply()
    }

    func setVisible(_ isVisible: Bool) {
        visible = isVisible
        apply()
    }

    private func apply() {
        let active = wantActive && visible
        if active {
            guard poller == nil else { return }
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } else {
            poller?.cancel()
            poller = nil
        }
    }

    func refresh() async {
        guard let client = AutoClient.current() else {
            overview = nil
            error = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            let o = try await client.overview()
            // A reply from an address that has since changed (typing in Settings) is stale.
            guard client.base == Config.automaticBase else { return }
            overview = o
            error = nil
            lastRefresh = Date()
            if pane == .activity { await loadActivity() }
            if let id = openShowID { await loadShow(id) }
        } catch is CancellationError {
        } catch {
            guard client.base == Config.automaticBase else { return }
            self.error = error.localizedDescription
        }
    }

    func loadActivity() async {
        guard let client = AutoClient.current() else { return }
        do {
            let feed = try await client.activity()
            activity = feed
            attention = feed.attention
            activityError = nil
        } catch is CancellationError {
        } catch {
            activityError = error.localizedDescription
        }
    }

    func openShow(_ id: Int?) {
        guard let id else { return }
        if openShowID != id { showDetail = nil; showError = nil }
        openShowID = id
        Task { await loadShow(id) }
    }

    func closeShow() {
        openShowID = nil
        showDetail = nil
        showError = nil
    }

    /// The show a seedbox row or an activity line is about, by its title.
    func showID(named title: String?) -> Int? {
        guard let title else { return nil }
        return overview?.following.first { $0.title == title }?.id
    }

    func loadShow(_ id: Int) async {
        guard let client = AutoClient.current() else { return }
        do {
            let detail = try await client.show(id: id)
            guard openShowID == id else { return }
            showDetail = detail
            showError = nil
        } catch is CancellationError {
        } catch {
            guard openShowID == id else { return }
            showError = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) async {
        guard let client = AutoClient.current() else { return }
        busy.insert("pause")
        defer { busy.remove("pause") }
        do {
            try await client.setPaused(paused)
            await refresh()
        } catch {
            notice = "Could not \(paused ? "pause" : "resume") Automatic: \(error.localizedDescription)"
        }
    }

    /// Searches for one episode at once: a better copy than the one there is, or any
    /// copy when there is none. `label` names it in the answer.
    func searchNow(episodeId: Int, label: String) async {
        guard let client = AutoClient.current() else { return }
        let key = "search-\(episodeId)"
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let r = try await client.searchNow(episodeId: episodeId)
            notice = r.taken != nil
                ? "\(label): took \(r.taken!). It downloads to the seedbox and goes to the NAS when it finishes."
                : "\(label): \(r.message)."
            await refresh()
        } catch {
            notice = "Could not search for \(label): \(error.localizedDescription)"
        }
    }

    /// Brings every episode of a season the library has to one format: `target`, one of
    /// the season's own. `label` names the season in the answer.
    func matchSeason(seriesId: Int, season: Int, target: String, label: String) async {
        guard let client = AutoClient.current() else { return }
        let key = "match-\(seriesId)-\(season)"
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let r = try await client.seasonMatch(seriesId: seriesId, season: season, target: target)
            notice = r.started > 0
                ? "\(label): \(r.message). Each downloads to the seedbox, is checked like any download, "
                    + "and replaces the file in the library when it finishes."
                : "\(label): \(r.message)."
            await refresh()
        } catch {
            notice = "Could not match \(label): \(error.localizedDescription)"
        }
    }

    func setQuality(_ show: AutoShow, level: String) async {
        guard let id = show.id, let client = AutoClient.current() else { return }
        busy.insert("quality-\(id)")
        defer { busy.remove("quality-\(id)") }
        do {
            _ = try await client.setQuality(seriesId: id, level: level)
            await refresh()
        } catch {
            notice = "Could not change \(show.title): \(error.localizedDescription)"
        }
    }

    func loadSuggestions() async {
        guard let client = AutoClient.current() else { return }
        suggestionsLoading = true
        defer { suggestionsLoading = false }
        do {
            let picks = await Task.detached { ChoiceLog.recentNames() }.value
            suggestions = try await client.suggestions(picks: picks)
            suggestionsError = nil
            suggestionsLoaded = true
        } catch is CancellationError {
        } catch {
            suggestionsError = error.localizedDescription
        }
    }

    func search(_ term: String) async {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let client = AutoClient.current() else { searchResults = []; return }
        searching = true
        defer { searching = false }
        do {
            searchResults = try await client.search(term)
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = error.localizedDescription
        }
    }

    func follow(_ show: AutoShow) async {
        guard let tvdb = show.tvdbId, let client = AutoClient.current() else { return }
        busy.insert(show.stableID)
        defer { busy.remove(show.stableID) }
        do {
            let added = try await client.follow(tvdbId: tvdb)
            notice = "Following \(added.title). New episodes download to the seedbox as they air."
            suggestions.removeAll { $0.tvdbId == tvdb }
            searchResults = searchResults.map { $0.tvdbId == tvdb ? added.marked(following: true) : $0 }
            await refresh()
        } catch {
            notice = "Could not follow \(show.title): \(error.localizedDescription)"
        }
    }

    func unfollow(_ show: AutoShow) async {
        guard let id = show.id, let client = AutoClient.current() else { return }
        busy.insert(show.stableID)
        defer { busy.remove(show.stableID) }
        do {
            try await client.unfollow(id: id)
            notice = "Stopped following \(show.title). Nothing was deleted."
            await refresh()
        } catch {
            notice = "Could not stop following \(show.title): \(error.localizedDescription)"
        }
    }

    func bringToNAS(_ t: AutoTorrent) async {
        guard let client = AutoClient.current() else { return }
        busy.insert(t.hash)
        defer { busy.remove(t.hash) }
        do {
            try await client.bringToNAS(hash: t.hash)
            notice = "Copying \(t.series ?? t.name ?? "the episode") to the NAS."
                + (overview?.seedbox.removeAfterCopy == true
                   ? " Once it is there, it is removed from the seedbox." : " The seedbox keeps its copy.")
            await refresh()
        } catch {
            notice = "Could not bring it to the NAS: \(error.localizedDescription)"
        }
    }

    /// Hands the NAS the qBittorrent sign-in Magnet already uses for magnets. Only on
    /// request: it is a credential leaving this Mac, so it is never sent by itself.
    func sendSeedboxLogin() async -> String? {
        guard let client = AutoClient.current() else { return "Set the NAS address and API token first." }
        let creds: QBCredentials? = await withCheckedContinuation { cont in
            QBCredentialStore.withCredentials { cont.resume(returning: $0) }
        }
        guard let creds else { return "Magnet has no qBittorrent sign-in to send. Set it in Torrent Client first." }
        do {
            try await client.seedboxLogin(username: creds.username, password: creds.password)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
