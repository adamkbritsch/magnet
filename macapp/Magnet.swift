import Foundation
import Security

struct QBCredentials: Equatable {
    var username: String
    var password: String
}

/// Shares the Keychain item with the qBittorrent Seedbox app on purpose — same
/// seedbox, same login, one place to change it.
enum QBCredentialStore {
    /// Configurable because this credential is commonly shared with a dedicated
    /// qBittorrent client app, which owns the Keychain item.
    private static var service: String { Config.qbKeychainService }
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

    /// Whether an item exists, WITHOUT reading it.
    ///
    /// Attributes-only queries are not subject to the item's ACL, so this never puts
    /// up a password box -- which matters because Settings displays this on open.
    static func exists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    static func save(username: String, password: String) {
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        for _ in 0..<32 where SecItemDelete(del as CFDictionary) == errSecSuccess {}

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(add as CFDictionary, nil)

        lock.lock()
        cached = username.isEmpty ? nil : QBCredentials(username: username, password: password)
        primed = true
        lock.unlock()
    }

    private static func read() -> QBCredentials? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? [String: Any],
              let acct = d[kSecAttrAccount as String] as? String,
              let data = d[kSecValueData as String] as? Data,
              let pw = String(data: data, encoding: .utf8), !acct.isEmpty
        else { return nil }
        return QBCredentials(username: acct, password: pw)
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
        guard http.statusCode == 200,
              (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Ok")
        else { throw MagnetError(message: "qBittorrent rejected the sign-in") }

        let fields = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: base)
        guard let s = cookies.first(where: { $0.name == "SID" })?.value else {
            throw MagnetError(message: "No session cookie returned")
        }
        return s
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
        if let sid { req.setValue("SID=\(sid)", forHTTPHeaderField: "Cookie") }
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MagnetError(message: "No response") }
        if http.statusCode == 403 { throw MagnetError(message: "Session expired") }
        guard http.statusCode == 200 else {
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

    /// Magnet links carry a display name in `dn=`; much friendlier than the hash.
    nonisolated static func displayName(for magnet: URL) -> String {
        let comps = URLComponents(url: magnet, resolvingAgainstBaseURL: false)
        if let dn = comps?.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty {
            return dn.replacingOccurrences(of: "+", with: " ")
        }
        return "torrent"
    }
}
