import Foundation
import Security

/// Every sign-in Magnet keeps, in ONE Keychain item that Magnet itself creates.
///
/// Why one. Magnet is signed without a Team ID, so macOS ties each Keychain approval to
/// this exact build: after a rebuild, every item the app reads puts up its own password
/// box again. Magnet used to read two -- the NAS proxy's sign-in and qBittorrent's, the
/// second created by the qBittorrent app it has since absorbed -- and the proxy one could
/// be read on two threads at once at launch, each read its own box. That was three
/// password boxes after an update. One item, read once per launch by whichever caller
/// gets there first while every other caller waits for that same read, is one box at
/// most, and none at all between rebuilds once "Always Allow" is chosen.
///
/// The old items are copied in once, the first time this item does not exist yet, and
/// left where they are: nothing is deleted.
enum SecretVault {
    struct Pair: Codable, Equatable {
        var user: String
        var pass: String
    }

    struct Contents: Codable, Equatable {
        var proxy: Pair?
        var qbittorrent: Pair?
    }

    static var service: String { "\(Config.bundleID).signins" }
    private static let account = "Magnet"
    private static let label = "Magnet sign-ins"

    /// Held across the Keychain read itself, so concurrent callers queue behind one read
    /// instead of each starting another -- and putting up another box.
    private static let lock = NSLock()
    private static var cached = Contents()
    private static var loaded = false

    /// Everything, read at most once per launch.
    static func contents() -> Contents {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            cached = loadOrMigrate()
            loaded = true
        }
        return cached
    }

    /// Whether a sign-in is saved, WITHOUT reading anything secret: attribute-only
    /// queries are not subject to an item's access rules, so this never asks for a
    /// password. Settings shows it the moment it opens.
    static func has(_ field: KeyPath<Contents, Pair?>, legacyService: String) -> Bool {
        lock.lock()
        if loaded { let v = cached[keyPath: field] != nil; lock.unlock(); return v }
        lock.unlock()
        return itemExists(service: service) || itemExists(service: legacyService)
    }

    static func update(_ change: (inout Contents) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var next = loaded ? cached : loadOrMigrate()
        change(&next)
        write(next)
        cached = next
        loaded = true
    }

    // MARK: -

    private static func loadOrMigrate() -> Contents {
        var contents: Contents
        if let data = readData(service: service, account: account) {
            contents = (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
        } else if itemExists(service: service) {
            // There but not readable: the box was declined. Leave it exactly as it is,
            // and do not reach past it for the old items either.
            return Contents()
        } else {
            contents = Contents()
        }

        // Copy in whatever is still only in an old item. Normally this happens once, the
        // first launch after the switch; a field filled since is never read again.
        var changed = false
        if contents.proxy == nil, let pair = readPair(service: Config.proxyKeychainService) {
            contents.proxy = pair
            changed = true
        }
        if contents.qbittorrent == nil, let pair = readPair(service: Config.qbKeychainService) {
            contents.qbittorrent = pair
            changed = true
        }
        if changed { write(contents) }
        return contents
    }

    private static func itemExists(service: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    private static func readData(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// An old one-sign-in item: the account is the username, the data the password.
    /// Only looked at when it exists, so a missing one costs no box.
    private static func readPair(service: String) -> Pair? {
        guard !service.isEmpty, service != Self.service, itemExists(service: service) else { return nil }
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
              let user = d[kSecAttrAccount as String] as? String, !user.isEmpty,
              let data = d[kSecValueData as String] as? Data,
              let pass = String(data: data, encoding: .utf8)
        else { return nil }
        return Pair(user: user, pass: pass)
    }

    /// Updated in place when it exists, so its access rules -- and the approval given to
    /// it -- carry over; added otherwise, which makes Magnet its creator.
    private static func write(_ contents: Contents) {
        guard let data = try? JSONEncoder().encode(contents) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        SecItemAdd(add as CFDictionary, nil)
    }
}
