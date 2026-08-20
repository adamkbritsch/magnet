import Foundation
import Network
import Security
import WebKit

/// How the web view reaches tracker sites.
enum X1337Route: String, CaseIterable, Identifiable {
    /// Straight out of this Mac. Fastest, and what works at home.
    case direct
    /// Tunnelled through the NAS with HTTP CONNECT over the tailnet.
    ///
    /// This has to be a *forward* proxy. A reverse proxy cannot serve a
    /// Cloudflare-challenged site: the challenge never completes (verified — it
    /// sat on "Just a moment..." indefinitely). CONNECT passes raw TLS through to
    /// the origin, so Cloudflare sees an ordinary browser and the challenge solves
    /// in about six seconds, same as direct.
    case viaNAS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .direct: return "Direct"
        case .viaNAS: return "Via NAS"
        }
    }

    var blurb: String {
        switch self {
        case .direct: return "Straight from this Mac. Fastest."
        case .viaNAS: return "Tunnelled through the NAS over Tailscale, for networks that block trackers."
        }
    }

    var symbol: String {
        switch self {
        case .direct: return "arrow.up.right"
        case .viaNAS: return "lock.shield"
        }
    }
}

/// The NAS forward-proxy password, kept in the Keychain rather than in the binary.
enum ProxyCredentialStore {
    private static var service: String { Config.proxyKeychainService }
    private static let lock = NSLock()
    private static var cached: (user: String, pass: String)?
    private static var primed = false

    static func load() -> (user: String, pass: String)? {
        lock.lock()
        if primed { let v = cached; lock.unlock(); return v }
        lock.unlock()

        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        var result: (String, String)?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let d = item as? [String: Any],
           let acct = d[kSecAttrAccount as String] as? String,
           let data = d[kSecValueData as String] as? Data,
           let pw = String(data: data, encoding: .utf8) {
            result = (acct, pw)
        }
        lock.lock(); cached = result; primed = true; lock.unlock()
        return result
    }

    /// Whether an item exists, WITHOUT reading it. Attributes-only queries are not
    /// subject to the item's ACL, so this never puts up a password box.
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

    static func save(user: String, pass: String) {
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        for _ in 0..<32 where SecItemDelete(del as CFDictionary) == errSecSuccess {}
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecValueData as String: Data(pass.utf8),
            kSecAttrLabel as String: "1337x NAS forward proxy",
        ]
        SecItemAdd(add as CFDictionary, nil)
        lock.lock(); cached = (user, pass); primed = true; lock.unlock()
    }

    /// Order matters: the environment is checked FIRST. Asking the Keychain whether
    /// it already holds something is itself an ACL check, so testing emptiness up
    /// front put a password box on every launch to answer a question that only
    /// matters on the one launch that carries provisioning variables.
    static func seedFromEnvironmentIfEmpty() {
        let env = ProcessInfo.processInfo.environment
        guard let u = env["MAGNET_PROXY_USER"], !u.isEmpty,
              let p = env["MAGNET_PROXY_PASS"], !p.isEmpty else { return }
        guard load() == nil else { return }
        save(user: u, pass: p)
        unsetenv("MAGNET_PROXY_PASS")
        unsetenv("MAGNET_PROXY_USER")
    }
}

@MainActor
final class RouteStore: ObservableObject {
    enum Status: Equatable {
        case probing
        case live(X1337Route)
        case offline(String)
    }

    @Published private(set) var status: Status = .probing
    @Published private(set) var active: X1337Route = .direct
    @Published var proxyHost: String
    @Published var proxyPort: UInt16
    /// nil = choose automatically; set = user pinned it.
    @Published private(set) var pinned: X1337Route?

    private let defaults = UserDefaults.standard
    private let session: URLSession

    init() {
        proxyHost = defaults.string(forKey: "proxy.host") ?? ""
        let p = defaults.integer(forKey: "proxy.port")
        proxyPort = p > 0 ? UInt16(p) : 8888
        if let raw = defaults.string(forKey: "route.pinned") {
            pinned = X1337Route(rawValue: raw)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: cfg)
    }

    func setProxy(host: String, port: UInt16) {
        proxyHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyPort = port
        defaults.set(proxyHost, forKey: "proxy.host")
        defaults.set(Int(port), forKey: "proxy.port")
    }

    func pin(_ route: X1337Route?) {
        pinned = route
        if let route { defaults.set(route.rawValue, forKey: "route.pinned") }
        else { defaults.removeObject(forKey: "route.pinned") }
    }

    /// The domain the app actually opens. Probing a fixed address would report the
    /// app offline in exactly the case a mirror exists to cover -- that domain being
    /// the one that died. Nil until a home site is configured.
    var homeProbeURL: URL?

    /// Reachability, not success. A Cloudflare challenge is a 403 and still means
    /// the site is reachable — only a transport failure means the network is
    /// blocking us.
    private func directReachable() async -> Bool {
        // Nothing to probe until a home site is configured.
        guard let url = homeProbeURL else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        do {
            _ = try await session.data(for: req)
            return true
        } catch {
            let ns = error as NSError
            // A response that merely errored at the HTTP layer still proves reach.
            return ns.domain != NSURLErrorDomain
        }
    }

    /// Guards the one-shot resume. The state handler and the timeout fire on
    /// different queues, so resuming a continuation twice is a real crash, not a
    /// theoretical one.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    private func nasReachable() async -> Bool {
        let host = proxyHost
        let port = proxyPort
        return await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 8888,
                using: .tcp
            )
            let once = OneShot()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled:
                    if once.claim() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.claim() { conn.cancel(); cont.resume(returning: false) }
            }
        }
    }

    func resolve() async {
        status = .probing
        let order: [X1337Route] = pinned.map { [$0] } ?? [.direct, .viaNAS]

        for route in order {
            let ok = route == .direct ? await directReachable() : await nasReachable()
            if ok {
                active = route
                status = .live(route)
                return
            }
        }
        // A pinned route that is down should still fall back rather than dead-end.
        if let pinned {
            let other: X1337Route = pinned == .direct ? .viaNAS : .direct
            let ok = other == .direct ? await directReachable() : await nasReachable()
            if ok {
                active = other
                status = .live(other)
                return
            }
        }
        status = .offline("Neither a direct connection nor the NAS could be reached.")
    }

    /// The proxy settings to hand WKWebsiteDataStore for the active route.
    /// True when the NAS route is in use but no proxy sign-in could be read.
    ///
    /// Worth surfacing rather than swallowing: a CONNECT proxy with no credentials
    /// answers 407 to everything, so EVERY site fails at once and the app looks
    /// broken rather than unauthenticated.
    @Published private(set) var proxyNeedsCredentials = false

    func proxyConfigurations() -> [ProxyConfiguration] {
        guard active == .viaNAS, !proxyHost.trimmingCharacters(in: .whitespaces).isEmpty
        else { proxyNeedsCredentials = false; return [] }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(rawValue: proxyPort) ?? 8888
        )
        let config = ProxyConfiguration(httpCONNECTProxy: endpoint)
        if let creds = ProxyCredentialStore.load() {
            config.applyCredential(username: creds.user, password: creds.pass)
            proxyNeedsCredentials = false
        } else {
            // Only a problem if one was ever saved; an open proxy needs none.
            proxyNeedsCredentials = ProxyCredentialStore.exists()
        }
        return [config]
    }
}
