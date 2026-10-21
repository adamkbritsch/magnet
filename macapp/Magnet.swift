import Foundation
import Security

struct QBCredentials: Equatable {
    var username: String
    var password: String
}

/// qBittorrent's sign-in, in Magnet's one sign-ins item (SecretVault). It used to share
/// an item with the separate qBittorrent app; that app is now Magnet's qBittorrent pane,
/// and its item is only where the sign-in is copied from, once.
enum QBCredentialStore {
    private static var legacyService: String { Config.qbKeychainService }
    private static let lock = NSLock()
    private static var cached: QBCredentials?
    private static var primed = false
    private static var loading = false
    private static var waiting: [(QBCredentials?) -> Void] = []

    static var current: QBCredentials? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Off the main thread: the first Keychain read after the app's code identity
    /// changes costs macOS several seconds of ACL evaluation.
    static func withCredentials(_ completion: @escaping (QBCredentials?) -> Void) {
        lock.lock()
        if primed {
            let v = cached
            lock.unlock()
            DispatchQueue.main.async { completion(v) }
            return
        }
        waiting.append(completion)
        let start = !loading
        loading = true
        lock.unlock()
        guard start else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let v = read()
            lock.lock()
            cached = v; primed = true; loading = false
            let cbs = waiting; waiting = []
            lock.unlock()
            DispatchQueue.main.async { cbs.forEach { $0(v) } }
        }
    }

    /// Whether a sign-in is saved, WITHOUT reading it, so this never puts up a password
    /// box -- which matters because Settings displays this on open.
    static func exists() -> Bool {
        SecretVault.has(\.qbittorrent, legacyService: legacyService)
    }

    static func save(username: String, password: String) {
        SecretVault.update {
            $0.qbittorrent = username.isEmpty ? nil : SecretVault.Pair(user: username, pass: password)
        }
        lock.lock()
        cached = username.isEmpty ? nil : QBCredentials(username: username, password: password)
        primed = true
        lock.unlock()
    }

    private static func read() -> QBCredentials? {
        guard let pair = SecretVault.contents().qbittorrent, !pair.user.isEmpty else { return nil }
        return QBCredentials(username: pair.user, password: pair.pass)
    }
}

enum MagnetResult {
    case added(String)
    case failed(String)
}

/// Pushes magnet links to qBittorrent, replacing the Torrent Control extension.
///
/// It posts to the **NAS reverse proxy** rather than straight at
/// the client's own port the way the extension did. That is the upgrade:
/// the extension silently fails on any network that blocks the seedbox, which is
/// exactly where this app is meant to be useful.
/// The session cookie qBittorrent hands back, whatever it decides to call it.
///
/// Two things about signing in changed under this app between 5.1 and 5.2, and each
/// on its own is enough to make the client look disconnected:
///
/// The reply became `204 No Content` with an empty body. This used to require `200`
/// AND a body beginning "Ok", so a perfectly good sign-in read as a rejection.
///
/// The cookie is no longer called `SID`. It is `QBT_SID_<port>` -- `QBT_SID_8080` on
/// this seedbox -- so looking for the name `SID` finds nothing, and sending one back
/// as `SID=...` would be ignored even if it had.
///
/// Neither is worth hardcoding again. Any 2xx is a yes, the cookie is found by shape
/// rather than by name, and its real name is carried with it.
/// Records which torrent was chosen, and what was on screen when it was.
///
/// The pick on its own is a list of filenames. What makes it worth keeping is the
/// page it was picked FROM: a search URL carries the query, so the pair reads as
/// "looked for this, chose that" -- which is the shape anything learning to choose
/// would need. The alternatives that were on the page and NOT chosen are not here;
/// recovering those would mean scraping the results, which is a bigger thing than
/// this and not worth doing silently.
///
/// Local file, append-only, never sent anywhere. Writing happens off the main thread
/// and every failure is swallowed: a logger must not cost a torrent.
enum ChoiceLog {
    nonisolated(unsafe) private static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/prompt-log", isDirectory: true)
    }

    /// The search terms, when the page is a search. Each site spells it differently,
    /// so this reads the two shapes that actually occur: a `q`-style query parameter,
    /// and a `/search/<terms>/` path segment.
    nonisolated static func query(from page: URL?) -> String? {
        guard let page else { return nil }
        if let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems {
            for key in ["q", "query", "search", "s", "keywords"] {
                if let v = items.first(where: { $0.name.lowercased() == key })?.value,
                   !v.isEmpty { return v }
            }
        }
        let parts = page.pathComponents.filter { $0 != "/" }
        if let i = parts.firstIndex(where: { ["search", "srch", "find"].contains($0.lowercased()) }),
           i + 1 < parts.count {
            let term = parts[i + 1]
            // 1337x puts the page number after the terms; a bare number is not a query.
            if !term.isEmpty, Int(term) == nil {
                return term.replacingOccurrences(of: "+", with: " ")
                    .replacingOccurrences(of: "%20", with: " ")
            }
        }
        return nil
    }

    nonisolated static func record(choice url: URL, page: URL?) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "name": MagnetSender.displayName(for: url),
            "hash": MagnetSender.infoHash(for: url) ?? "",
            "kind": url.scheme?.lowercased() == "magnet" ? "magnet" : "torrent-file",
            "page": page?.absoluteString ?? "",
            "site": page?.host.map(registrableDomain) ?? "",
            "query": query(from: page) ?? "",
        ]
        // Off the main thread: this is a disk write on the path of a click.
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONSerialization.data(withJSONObject: entry,
                                                         options: [.sortedKeys]),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            let dir = directory
            let file = dir.appendingPathComponent("torrent-choices.jsonl")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// The names of the most recent picks, newest first and without repeats. Automatic
    /// mode turns these into "you have been picking this show" suggestions; only the
    /// names are used, never the pages they came from.
    nonisolated static func recentNames(limit: Int = 60) -> [String] {
        let file = directory.appendingPathComponent("torrent-choices.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = obj["name"] as? String, !name.isEmpty, name != "torrent",
                  seen.insert(name).inserted else { continue }
            out.append(name)
            if out.count >= limit { break }
        }
        return out
    }
}

enum QBSession {
    /// The `Cookie:` header value to send back, e.g. `QBT_SID_8080=abc123`.
    static func cookieHeader(from http: HTTPURLResponse, base: URL) -> String? {
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: base)
        guard let cookie = cookies.first(where: { isSession($0.name) }) else { return nil }
        return "\(cookie.name)=\(cookie.value)"
    }

    /// `SID` as it used to be, `QBT_SID_8080` as it is now, and whatever port comes next.
    static func isSession(_ name: String) -> Bool {
        let n = name.uppercased()
        return n == "SID" || n.hasPrefix("QBT_SID")
    }

    /// A sign-in qBittorrent accepted. 200 with "Ok." for years; 204 and empty since
    /// 5.2. The cookie is the real evidence either way, so the status only has to not
    /// be a refusal.
    static func accepted(_ status: Int) -> Bool { (200...299).contains(status) }
}

actor MagnetSender {
    private var sid: String?
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpShouldSetCookies = false
        // Deliberately NOT proxied: the seedbox WebUI is reached through the NAS
        // reverse proxy over the tailnet, not through the CONNECT proxy that the
        // web view uses for tracker sites.
        session = URLSession(configuration: cfg)
    }

    func send(_ magnet: URL, base: URL, credentials: QBCredentials) async -> MagnetResult {
        do {
            if sid == nil { sid = try await login(base: base, credentials: credentials) }
            do {
                try await add(magnet, base: base)
            } catch {
                // A stale session is the common failure; re-auth once and retry.
                sid = try await login(base: base, credentials: credentials)
                try await add(magnet, base: base)
            }
            return .added(Self.displayName(for: magnet))
        } catch let e as MagnetError {
            return .failed(e.message)
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    private struct MagnetError: Error { let message: String }

    /// Returns the `Cookie:` header value for the session, not a bare token: the
    /// cookie's NAME is part of it now and varies with the client's port.
    private func login(base: URL, credentials: QBCredentials) async throws -> String {
        guard let url = URL(string: "api/v2/auth/login", relativeTo: base) else {
            throw MagnetError(message: "Bad qBittorrent URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("username=\(esc(credentials.username))&password=\(esc(credentials.password))".utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MagnetError(message: "No response") }
        guard QBSession.accepted(http.statusCode) else {
            // qBittorrent answers 200 with "Fails." for a bad password, so a body that
            // says so is worth repeating even when the status did not object.
            throw MagnetError(message: "qBittorrent rejected the sign-in (HTTP \(http.statusCode))")
        }
        let body = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("fail") {
            throw MagnetError(message: "qBittorrent rejected the sign-in")
        }
        guard let cookie = QBSession.cookieHeader(from: http, base: base) else {
            throw MagnetError(message: "No session cookie returned")
        }
        return cookie
    }

    private func add(_ magnet: URL, base: URL) async throws {
        guard let url = URL(string: "api/v2/torrents/add", relativeTo: base) else {
            throw MagnetError(message: "Bad qBittorrent URL")
        }
        // qBittorrent's /torrents/add expects multipart/form-data.
        let boundary = "----x1337app\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"urls\"\r\n\r\n".utf8))
        body.append(Data(magnet.absoluteString.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Sent back under the name it arrived with. Hardcoding `SID=` worked until the
        // cookie was renamed to QBT_SID_<port>, after which every call was unauthorised
        // no matter how well the sign-in had gone.
        if let sid { req.setValue(sid, forHTTPHeaderField: "Cookie") }
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MagnetError(message: "No response") }
        if http.statusCode == 403 { throw MagnetError(message: "Session expired") }
        guard QBSession.accepted(http.statusCode) else {
            throw MagnetError(message: "qBittorrent returned HTTP \(http.statusCode)")
        }
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().contains("fail") {
            throw MagnetError(message: "qBittorrent refused the torrent")
        }
    }

    private func esc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Whether this is a real magnet link and not something wearing the scheme.
    ///
    /// A magnet without an info hash cannot identify a torrent, so there is nothing a
    /// client could do with it. Decoy links among the real ones are the reason to
    /// check: the scheme is trivial to forge, the app hands anything using it straight
    /// to the torrent client, and a client is a poor place to discover the difference.
    /// The info hash, which is the only part of a magnet that names the torrent --
    /// `dn` is a label the page chose and the trackers are incidental.
    ///
    /// Parsed here rather than borrowed from RedirectGuard: this file would otherwise
    /// drag the navigation guard, and WebKit behind it, into every test suite that
    /// touches sending a torrent.
    nonisolated static func infoHash(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "magnet" else { return nil }
        let raw = url.absoluteString.lowercased()
        guard let mark = raw.range(of: "xt=urn:bt") else { return nil }
        let rest = raw[mark.upperBound...]
        let hash = rest.drop(while: { $0 != ":" }).dropFirst().prefix(while: { $0 != "&" })
        return hash.isEmpty ? nil : String(hash)
    }

    nonisolated static func isValidMagnet(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "magnet" else { return false }
        // `URLComponents` will not parse a magnet's query on its own, since the part
        // after the scheme is not a path.
        let raw = url.absoluteString
        guard let q = raw.firstIndex(of: "?") else { return false }
        let query = raw[raw.index(after: q)...]

        for field in query.split(separator: "&") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "xt" else { continue }
            let value = parts[1].lowercased()
            if value.hasPrefix("urn:btih:") {
                let hash = value.dropFirst("urn:btih:".count)
                // Either spelling of a v1 info hash.
                if hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) { return true }
                if hash.count == 32,
                   hash.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "2" && $0 <= "7") }) {
                    return true
                }
            }
            if value.hasPrefix("urn:btmh:") {
                let hash = value.dropFirst("urn:btmh:".count)
                if hash.count >= 68, hash.allSatisfy({ $0.isHexDigit }) { return true }
            }
        }
        return false
    }

    /// Magnet links carry a display name in `dn=`; much friendlier than the hash.
    nonisolated static func displayName(for magnet: URL) -> String {
        let comps = URLComponents(url: magnet, resolvingAgainstBaseURL: false)
        if let dn = comps?.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty {
            return dn.replacingOccurrences(of: "+", with: " ")
        }
        return "torrent"
    }
}
