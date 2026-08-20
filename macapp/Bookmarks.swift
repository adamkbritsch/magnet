import Foundation
import SQLite3

struct Bookmark: Identifiable, Equatable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }

    /// Short label for a chip. Page titles range from "DODI Repacks" to a
    /// paragraph-long FitGirl anti-scam notice, so this picks the most
    /// name-like fragment rather than trusting the title wholesale.
    var chipLabel: String {
        let separators = CharacterSet(charactersIn: "|\u{2013}\u{2014}\u{2022}\u{00B7}")
        var segments = title.components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Words that name a page, not a site.
        let generic: Set<String> = [
            "login", "home", "index", "dashboard", "official", "welcome",
            "sign in", "download", "downloads", "page", "client area",
            "the", "a", "an", "free", "new",
        ]
        segments = segments.filter { !generic.contains($0.lowercased()) }

        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "-", with: "")

        /// A title fragment only names the *site* if it shows up in the hostname.
        /// "Unabridged Audiobooks Free Download" on theaudiobookbay.se does not, so
        /// the domain is the better label there.
        func namesTheSite(_ text: String) -> Bool {
            let token = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
            return token.contains { host.contains($0) }
        }

        if let best = segments.filter({ $0.count >= 3 && $0.count <= 22 })
            .min(by: { $0.count < $1.count }), namesTheSite(best) {
            return best
        }
        if let first = segments.first?.split(separator: " ").first.map(String.init),
           first.count >= 3, first.count <= 16,
           !generic.contains(first.lowercased()), namesTheSite(first) {
            return first
        }
        return Self.siteName(from: url)
    }

    /// Registrable domain, not the leftmost label — `srv1234.example-host.com`
    /// should read as "Example-host", not "Srv1234".
    private static func siteName(from url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let labels = host.split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return host }
        // Handle two-part suffixes like .co.uk by stepping back past short tails.
        var idx = labels.count - 2
        if labels.count >= 3, labels[labels.count - 2].count <= 3, labels[labels.count - 1].count <= 3 {
            idx = labels.count - 3
        }
        var name = labels[max(0, idx)]
        // "theaudiobookbay" reads better as "Audiobookbay".
        if name.count > 6, name.hasPrefix("the") { name = String(name.dropFirst(3)) }
        if name.count <= 5 { return name.uppercased() }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Reads a named bookmark folder out of Firefox and keeps it current, alongside a
/// list of sites added by hand.
///
/// Everything here is deliberately discovery-based rather than path-based: profiles
/// get renamed, the default profile changes between channels, and `places.sqlite`
/// moves with them. So the profile is found by *looking for the folder*, not by
/// trusting a stored path.
///
/// Nothing is seeded. With no folder name configured there is no import at all, and
/// with no manual sites the bar is empty -- which is what a fresh install looks like.
@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var hidden: Set<String> = []
    /// URLs shown first, in this order, ahead of normal folder order.
    @Published private(set) var pinnedFirst: [String] = []
    /// Sites added by hand rather than mirrored from Firefox.
    @Published private(set) var extras: [Bookmark] = []
    @Published private(set) var lastError: String?
    @Published private(set) var folderFound = false

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastSignature: String = ""

    private var settings: AppSettings { AppSettings.shared }

    /// The Firefox folder currently being mirrored, or empty when import is off.
    var folderName: String { settings.bookmarkFolder }

    init() {
        hidden = Set(defaults.array(forKey: "bookmarks.hidden") as? [String] ?? [])
        pinnedFirst = defaults.array(forKey: "bookmarks.pinned") as? [String] ?? []
        reloadExtras()
    }

    func start() {
        refresh()
        // Cheap: the poll only reads file stat unless something actually changed.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Manually added sites

    func reloadExtras() {
        let stored = (defaults.array(forKey: "bookmarks.extra") as? [[String: String]]) ?? []
        extras = stored.compactMap { entry in
            guard let title = entry["title"], let raw = entry["url"], let url = URL(string: raw)
            else { return nil }
            return Bookmark(title: title, url: url)
        }
    }

    private func persistExtras() {
        defaults.set(extras.map { ["title": $0.title, "url": $0.url.absoluteString] },
                     forKey: "bookmarks.extra")
        objectWillChange.send()
    }

    @discardableResult
    func addExtra(title: String, url: URL) -> Bool {
        guard !extras.contains(where: { $0.url == url }) else { return false }
        extras.append(Bookmark(title: title.isEmpty ? (url.host ?? "Site") : title, url: url))
        persistExtras()
        return true
    }

    func removeExtra(_ bookmark: Bookmark) {
        extras.removeAll { $0.url == bookmark.url }
        // Leaving stale hide/pin entries behind would silently hide the site if it
        // were ever added back.
        hidden.remove(bookmark.id)
        pinnedFirst.removeAll { $0 == bookmark.id }
        defaults.set(Array(hidden), forKey: "bookmarks.hidden")
        defaults.set(pinnedFirst, forKey: "bookmarks.pinned")
        persistExtras()
    }

    var isExtra: (Bookmark) -> Bool { { [extras] bm in extras.contains { $0.url == bm.url } } }

    // MARK: - Visibility

    func setHidden(_ bookmark: Bookmark, _ isHidden: Bool) {
        if isHidden { hidden.insert(bookmark.id) } else { hidden.remove(bookmark.id) }
        defaults.set(Array(hidden), forKey: "bookmarks.hidden")
        objectWillChange.send()
    }

    func unhideAll() {
        hidden.removeAll()
        defaults.set([String](), forKey: "bookmarks.hidden")
        objectWillChange.send()
    }

    /// Firefox folder entries first, then the manual additions.
    private var allSources: [Bookmark] {
        let known = Set(bookmarks.map(\.id))
        return bookmarks + extras.filter { !known.contains($0.id) }
    }

    var visible: [Bookmark] {
        let shown = allSources.filter { !hidden.contains($0.id) }
        let pinnedSet = Set(pinnedFirst)
        // Pinned chips lead, in pin order; everything else keeps Firefox's order.
        let lead = pinnedFirst.compactMap { id in shown.first { $0.id == id } }
        return lead + shown.filter { !pinnedSet.contains($0.id) }
    }

    func isPinned(_ bookmark: Bookmark) -> Bool { pinnedFirst.contains(bookmark.id) }

    func setPinned(_ bookmark: Bookmark, _ pin: Bool) {
        pinnedFirst.removeAll { $0 == bookmark.id }
        if pin { pinnedFirst.insert(bookmark.id, at: 0) }
        defaults.set(pinnedFirst, forKey: "bookmarks.pinned")
        objectWillChange.send()
    }

    var hiddenBookmarks: [Bookmark] { allSources.filter { hidden.contains($0.id) } }

    // MARK: - Firefox discovery

    private static func profileDirectories() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let firefox = support?.appendingPathComponent("Firefox") else { return [] }

        var dirs: [URL] = []
        // profiles.ini is the documented index and survives version changes.
        if let ini = try? String(contentsOf: firefox.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            for line in ini.split(separator: "\n") {
                guard line.hasPrefix("Path=") else { continue }
                let path = String(line.dropFirst("Path=".count)).trimmingCharacters(in: .whitespaces)
                dirs.append(firefox.appendingPathComponent(path))
            }
        }
        // Belt and braces: if the ini is ever missing or reformatted, just look.
        let profilesDir = firefox.appendingPathComponent("Profiles")
        if let listing = try? FileManager.default.contentsOfDirectory(at: profilesDir,
                                                                     includingPropertiesForKeys: nil) {
            for url in listing where !dirs.contains(url) { dirs.append(url) }
        }
        return dirs.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path)
        }
    }

    /// mtime+size of every candidate places.sqlite (and its WAL). Cheap enough to
    /// poll, and changes the moment a bookmark is added.
    private static func signature(_ dbs: [URL]) -> String {
        var parts: [String] = []
        for db in dbs {
            for suffix in ["", "-wal"] {
                let p = db.path + suffix
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p) {
                    let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let s = (attrs[.size] as? Int) ?? 0
                    parts.append("\(p):\(Int(m)):\(s)")
                }
            }
        }
        return parts.joined(separator: "|")
    }

    /// Sites that are infrastructure rather than a place to obtain things.
    ///
    /// Own-infrastructure hosts are filtered structurally -- private/CGNAT/.local --
    /// plus whatever domains the user has named, so a seedbox's four separate service
    /// bookmarks all disappear behind one rule.
    private static func isPrivateHost(_ host: String, infrastructure: [String]) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".lan") { return true }
        if h.hasSuffix(".ts.net") { return true }
        for infra in infrastructure {
            let d = infra.lowercased().trimmingCharacters(in: .whitespaces)
            guard !d.isEmpty else { continue }
            if h == d || h.hasSuffix("." + d) { return true }
        }

        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (127, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true      // CGNAT -- the tailnet range
        case (169, 254): return true
        default: return false
        }
    }

    func refresh(force: Bool = false) {
        let folder = folderName.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else {
            // Import is off, which is the default. Manual sites still show.
            if !bookmarks.isEmpty { bookmarks = [] }
            folderFound = false
            lastError = nil
            return
        }

        let dbs = Self.profileDirectories().map { $0.appendingPathComponent("places.sqlite") }
        guard !dbs.isEmpty else {
            lastError = "No Firefox profile with bookmarks was found."
            folderFound = false
            return
        }

        let sig = Self.signature(dbs)
        if !force && sig == lastSignature { return }
        lastSignature = sig

        let infrastructure = settings.infrastructureHosts
        for db in dbs {
            if let found = Self.readFolder(from: db, named: folder), !found.isEmpty {
                let filtered = found.filter { bm in
                    guard let host = bm.url.host else { return false }
                    guard ["http", "https"].contains(bm.url.scheme?.lowercased() ?? "") else { return false }
                    return !Self.isPrivateHost(host, infrastructure: infrastructure)
                }
                if filtered != bookmarks { bookmarks = filtered }
                folderFound = true
                lastError = nil
                return
            }
        }
        folderFound = false
        lastError = "No \u{201C}\(folder)\u{201D} bookmark folder found in any Firefox profile."
    }

    // MARK: - SQLite

    private static func readFolder(from db: URL, named folder: String) -> [Bookmark]? {
        // Firefox holds places.sqlite open with WAL; opening it directly can see a
        // stale or locked view. Copy the trio to temp and read that instead.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("x1337-places-\(UUID().uuidString).sqlite")
        defer {
            for s in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp.path + s)
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            let src = db.path + suffix
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.copyItem(atPath: src, toPath: tmp.path + suffix)
            }
        }
        guard FileManager.default.fileExists(atPath: tmp.path) else { return nil }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT b.title, p.url
        FROM moz_bookmarks b
        JOIN moz_places p ON p.id = b.fk
        WHERE b.type = 1 AND b.parent = (
            SELECT id FROM moz_bookmarks
            WHERE type = 2 AND lower(title) = lower(?) LIMIT 1
        )
        ORDER BY b.position
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, folder, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var out: [Bookmark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            guard let urlText = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let url = URL(string: urlText) else { continue }
            out.append(Bookmark(title: title, url: url))
        }
        return out
    }
}
