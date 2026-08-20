import Foundation

/// A hand-checked mirror set. `page`, when present, is the Wikipedia article whose
/// infobox publishes the live domain list.
struct CuratedMirror: Equatable, Identifiable {
    var id: String
    var name: String
    var page: String?
    var urls: [String]

    init(id: String, name: String, page: String? = nil, urls: [String]) {
        self.id = id; self.name = name; self.page = page; self.urls = urls
    }

    init?(plist: [String: Any]) {
        guard let id = plist["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.name = (plist["name"] as? String) ?? id
        self.page = (plist["page"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.urls = (plist["urls"] as? [String]) ?? []
    }

    var plist: [String: Any] {
        var out: [String: Any] = ["id": id, "name": name, "urls": urls]
        if let page, !page.isEmpty { out["page"] = page }
        return out
    }
}

/// Everything that used to be a constant compiled into the source.
///
/// The shipped defaults are deliberately EMPTY: no sites, no bookmark folder, no home
/// URL, no NAS. Anything else would be one person's setup baked into everyone's build.
/// A configured machine fills these in through Settings, or in bulk with
/// `tools/seed-local.sh`.
///
/// Features degrade quietly rather than being gated behind switches -- an unset
/// qBittorrent URL simply means magnets are not forwarded, and an unset NAS means
/// downloads stay local. There is nothing to turn on, only something to fill in.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard
    /// Suppresses persistence while `init` populates the published properties.
    private var loading = true

    // MARK: Identity

    /// Also the UserDefaults domain, so it must never be changed casually: a new id
    /// orphans every setting and every Keychain grant tied to the old one.
    nonisolated static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "x1337"
    }

    nonisolated static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "x1337"
    }

    // MARK: Where the app opens

    @Published var homeURL: String { didSet { put("home.url", homeURL) } }

    var home: URL? { URL(string: homeURL.trimmingCharacters(in: .whitespaces)) }

    // MARK: Sites

    /// Firefox bookmark folder mirrored into the bar. Empty means no import at all,
    /// which is the shipped default -- one person's folder name is not a sensible
    /// thing to guess at.
    @Published var bookmarkFolder: String { didSet { put("bookmarks.folderName", bookmarkFolder) } }

    /// Hosts that are infrastructure rather than a place to obtain things, filtered
    /// out of the bar on top of the structural private/CGNAT/.local rules.
    @Published var infrastructureHosts: [String] { didSet { put("bookmarks.infraHosts", infrastructureHosts) } }

    // MARK: Route

    @Published var proxyHost: String { didSet { put("proxy.host", proxyHost) } }
    @Published var proxyPort: Int { didSet { put("proxy.port", proxyPort) } }
    @Published var proxyKeychainService: String { didSet { put("proxy.keychainService", proxyKeychainService) } }

    var proxyConfigured: Bool { !proxyHost.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Torrent client

    @Published var qbBaseURL: String { didSet { put("qb.baseURL", qbBaseURL) } }
    /// Separate from the proxy service because this credential is often shared with a
    /// dedicated qBittorrent client app.
    @Published var qbKeychainService: String { didSet { put("qb.keychainService", qbKeychainService) } }

    var qbBase: URL? { URL(string: qbBaseURL.trimmingCharacters(in: .whitespaces)) }
    var qbConfigured: Bool { qbBase != nil }

    // MARK: Download archive

    @Published var nasHost: String { didSet { put("nas.host", nasHost) } }
    @Published var nasShare: String { didSet { put("nas.share", nasShare) } }
    @Published var nasUser: String { didSet { put("nas.user", nasUser) } }
    @Published var archiveRoot: String { didSet { put("archive.root", archiveRoot) } }
    @Published var archiveLocalPath: String { didSet { put("archive.localPath", archiveLocalPath) } }
    /// Category raw value -> folder name.
    @Published var categoryFolders: [String: String] { didSet { put("archive.folders", categoryFolders) } }

    /// A share can only be mounted if we know all three.
    var nasConfigured: Bool {
        ![nasHost, nasShare, nasUser].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var localRoot: URL {
        let path = archiveLocalPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return Self.defaultLocalRoot }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    nonisolated static var defaultLocalRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(appName)-Library")
    }

    nonisolated static let defaultCategoryFolders = [
        "books": "Books", "moviesAndTV": "TV", "games": "Games",
        "everything": "Misc", "other": "Misc",
    ]

    // MARK: Mirrors

    @Published var curatedMirrors: [CuratedMirror] {
        didSet { put("mirrors.curated", curatedMirrors.map(\.plist)) }
    }
    @Published var fmhyEnabled: Bool { didSet { put("mirrors.fmhy.enabled", fmhyEnabled) } }
    /// Hours between upstream refreshes. Domains get seized, so this is checked far
    /// more often than a plain list of links would justify.
    @Published var mirrorRefreshHours: Int { didSet { put("mirrors.refreshHours", mirrorRefreshHours) } }

    var mirrorRefreshInterval: TimeInterval { TimeInterval(max(1, mirrorRefreshHours) * 3600) }

    // MARK: Appearance

    /// Off by default: a browser should not silently repaint every site someone visits.
    @Published var unifiedStyleEnabled: Bool { didSet { put("style.enabled", unifiedStyleEnabled) } }
    /// Which palette. `SiteStyle.customThemeID` means "use `siteCSS` verbatim".
    @Published var styleTheme: String { didSet { put("style.theme", styleTheme) } }
    /// The custom stylesheet. Empty falls back to a built-in palette, so the editor is
    /// always pre-filled with something real rather than a blank box.
    @Published var siteCSS: String { didSet { put("style.css", siteCSS) } }

    var effectiveSiteCSS: String {
        guard styleTheme == SiteStyle.customThemeID else {
            return SiteStyle.css(for: styleTheme)
        }
        let custom = siteCSS.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? SiteStyle.defaultCSS : custom
    }

    // MARK: -

    private init() {
        let d = UserDefaults.standard
        homeURL = d.string(forKey: "home.url") ?? ""
        bookmarkFolder = d.string(forKey: "bookmarks.folderName") ?? ""
        infrastructureHosts = d.stringArray(forKey: "bookmarks.infraHosts") ?? []

        proxyHost = d.string(forKey: "proxy.host") ?? ""
        let port = d.integer(forKey: "proxy.port")
        proxyPort = port > 0 ? port : 8888
        proxyKeychainService = d.string(forKey: "proxy.keychainService")
            ?? "\(AppSettings.bundleID).proxy"

        qbBaseURL = d.string(forKey: "qb.baseURL") ?? ""
        qbKeychainService = d.string(forKey: "qb.keychainService")
            ?? "\(AppSettings.bundleID).qbittorrent"

        nasHost = d.string(forKey: "nas.host") ?? ""
        nasShare = d.string(forKey: "nas.share") ?? ""
        nasUser = d.string(forKey: "nas.user") ?? ""
        archiveRoot = d.string(forKey: "archive.root") ?? "Direct"
        archiveLocalPath = d.string(forKey: "archive.localPath") ?? ""
        categoryFolders = (d.dictionary(forKey: "archive.folders") as? [String: String])
            ?? AppSettings.defaultCategoryFolders

        curatedMirrors = ((d.array(forKey: "mirrors.curated") as? [[String: Any]]) ?? [])
            .compactMap(CuratedMirror.init(plist:))
        fmhyEnabled = (d.object(forKey: "mirrors.fmhy.enabled") as? Bool) ?? true
        let hours = d.integer(forKey: "mirrors.refreshHours")
        mirrorRefreshHours = hours > 0 ? hours : 6

        unifiedStyleEnabled = d.bool(forKey: "style.enabled")
        styleTheme = d.string(forKey: "style.theme") ?? SiteStyle.themes[0].id
        siteCSS = d.string(forKey: "style.css") ?? ""

        loading = false
    }

    /// An empty string is an absent setting, not a stored blank -- otherwise a cleared
    /// field would persist as "" and shadow any future default.
    private func put(_ key: String, _ value: Any) {
        guard !loading else { return }
        if let text = value as? String, text.trimmingCharacters(in: .whitespaces).isEmpty {
            d.removeObject(forKey: key)
        } else if let list = value as? [Any], list.isEmpty {
            d.removeObject(forKey: key)
        } else {
            d.set(value, forKey: key)
        }
    }

    /// Used by the tests, and by anyone who wants to start over.
    func resetAll() {
        for key in ["home.url", "bookmarks.folderName", "bookmarks.infraHosts",
                    "proxy.host", "proxy.port", "proxy.keychainService",
                    "qb.baseURL", "qb.keychainService",
                    "nas.host", "nas.share", "nas.user", "archive.root",
                    "archive.localPath", "archive.folders",
                    "mirrors.curated", "mirrors.fmhy.enabled", "mirrors.refreshHours",
                    "style.enabled", "style.css", "style.theme"] {
            d.removeObject(forKey: key)
        }
    }
}

/// Reads for code that cannot touch the MainActor-isolated store -- Keychain helpers,
/// download filing, reachability probes.
///
/// UserDefaults is itself thread-safe, so this is not a cache; it exists so the key
/// names and their fallbacks live in exactly one place rather than being repeated at
/// each nonisolated call site.
enum Config {
    private static var d: UserDefaults { .standard }
    private static func string(_ key: String) -> String {
        (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "x1337" }

    static var proxyKeychainService: String {
        let s = string("proxy.keychainService")
        return s.isEmpty ? "\(bundleID).proxy" : s
    }

    static var qbKeychainService: String {
        let s = string("qb.keychainService")
        return s.isEmpty ? "\(bundleID).qbittorrent" : s
    }

    static var nasHost: String { string("nas.host") }
    static var nasShare: String { string("nas.share") }
    static var nasUser: String { string("nas.user") }

    /// All three are needed to mount anything, so an incomplete setup counts as none.
    static var nasConfigured: Bool {
        !nasHost.isEmpty && !nasShare.isEmpty && !nasUser.isEmpty
    }

    static var archiveRoot: String {
        let s = string("archive.root")
        return s.isEmpty ? "Direct" : s
    }

    static var localRoot: URL {
        let s = string("archive.localPath")
        if s.isEmpty { return AppSettings.defaultLocalRoot }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }

    /// Folder for a category, by its raw value.
    static func categoryFolder(_ raw: String) -> String {
        let map = (d.dictionary(forKey: "archive.folders") as? [String: String])
            ?? AppSettings.defaultCategoryFolders
        return map[raw] ?? AppSettings.defaultCategoryFolders[raw] ?? "Misc"
    }
}
