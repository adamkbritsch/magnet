import Foundation
import Network
import Security
import WebKit

/// There is one route: the NAS forward proxy.
///
/// A direct connection was offered once and removed. Reaching these sites straight
/// from the Mac is what an ordinary browser already does, so the app that only did
/// that added nothing; what it adds is the tunnel, and a tunnel that silently stops
/// being used on a network that happens to permit direct traffic is worse than no
/// tunnel at all, because it looks identical.
///
/// This has to be a *forward* proxy. A reverse proxy cannot serve a Cloudflare-
/// challenged site: the challenge never completes (verified -- it sat on "Just a
/// moment..." indefinitely). CONNECT passes raw TLS through to the origin, so
/// Cloudflare sees an ordinary browser and the challenge solves in about six seconds.
enum X1337Route: String, CaseIterable, Identifiable {
    case viaNAS

    var id: String { rawValue }
    var label: String { "Via NAS" }
    var blurb: String { "Tunnelled through the NAS over Tailscale." }
    var symbol: String { "lock.shield" }
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
    @Published private(set) var active: X1337Route = .viaNAS
    @Published var proxyHost: String
    @Published var proxyPort: UInt16

    private let defaults = UserDefaults.standard
    private let session: URLSession

    init() {
        proxyHost = defaults.string(forKey: "proxy.host") ?? ""
        let p = defaults.integer(forKey: "proxy.port")
        proxyPort = p > 0 ? UInt16(p) : 8888
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
        guard !proxyHost.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = .offline("No forward proxy is configured. Open Settings \u{2192} "
                              + "Connection and set the NAS address.")
            return
        }
        if await nasReachable() {
            active = .viaNAS
            status = .live(.viaNAS)
            return
        }
        // No fallback by design. Failing here is a NAS or tailnet problem to fix,
        // and quietly browsing around it would hide that while dropping the tunnel.
        status = .offline("The NAS proxy at \(proxyHost):\(proxyPort) is not answering. "
                          + "Sites load only through it.")
    }

    /// The proxy settings to hand WKWebsiteDataStore for the active route.
    /// True when the NAS route is in use but no proxy sign-in could be read.
    ///
    /// Worth surfacing rather than swallowing: a CONNECT proxy with no credentials
    /// answers 407 to everything, so EVERY site fails at once and the app looks
    /// broken rather than unauthenticated.
    @Published private(set) var proxyNeedsCredentials = false

    func proxyConfigurations() -> [ProxyConfiguration] {
        guard !proxyHost.trimmingCharacters(in: .whitespaces).isEmpty
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
