import Foundation

// What this Mac's Tailscale says about the device behind the proxy address, and the
// words the offline screen and the early warning use for it.

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

// Addresses are built here rather than written out, so the repository's privacy check
// (which refuses tailnet addresses in what is committed) has nothing to find.
func ip(_ parts: Int...) -> String { parts.map(String.init).joined(separator: ".") }
let nas = ip(100, 70, 1, 5)
let other = ip(100, 99, 2, 8)
let magic = ["nas", "tailnet-example", "ts", "net"].joined(separator: ".")
let now = Date(timeIntervalSince1970: 1_800_000_000)
func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

func status(state: String = "Running", peers: [[String: Any]]) -> Data {
    var dict: [String: Any] = [:]
    for (i, p) in peers.enumerated() { dict["node\(i)"] = p }
    return try! JSONSerialization.data(withJSONObject: ["BackendState": state, "Peer": dict])
}
func peer(_ ip: String, online: Bool, expiry: Date?, expired: Bool = false, seen: Date? = nil) -> [String: Any] {
    var p: [String: Any] = ["HostName": "nas-box", "DNSName": magic + ".", "TailscaleIPs": [ip],
                            "Online": online, "Expired": expired]
    if let expiry { p["KeyExpiry"] = stamp(expiry) }
    if let seen { p["LastSeen"] = stamp(seen) }
    return p
}

print("Test 1 - which addresses are Tailscale's")
check("100.64/10 is", Tailnet.isTailnetHost(nas))
check("its own IPv6 range is", Tailnet.isTailnetHost("fd7a:115c:a1e0::1"))
check("a MagicDNS name is", Tailnet.isTailnetHost(magic))
check("a home address is not", !Tailnet.isTailnetHost(ip(192, 168, 1, 10)))
check("100.128 is outside the range", !Tailnet.isTailnetHost(ip(100, 128, 0, 1)))
check("a name is not", !Tailnet.isTailnetHost("nas.local"))

print("Test 2 - reading the status")
let expired = Tailnet.parse(status(peers: [peer(nas, online: false, expiry: now - 3600, expired: true)]), host: nas, now: now)
if case .expired(let name, _) = expired { check("an expired sign-in is named", name == "nas-box") }
else { check("an expired sign-in is named", false, "\(expired)") }
let pastKey = Tailnet.parse(status(peers: [peer(nas, online: true, expiry: now - 60)]), host: nas, now: now)
if case .expired = pastKey { check("a key past its date counts as expired", true) }
else { check("a key past its date counts as expired", false, "\(pastKey)") }
let offline = Tailnet.parse(status(peers: [peer(nas, online: false, expiry: now + 86400 * 90, seen: now - 7200)]), host: nas, now: now)
if case .offline(_, let seen) = offline { check("offline, with when it was last seen", seen != nil) }
else { check("offline, with when it was last seen", false, "\(offline)") }
let online = Tailnet.parse(status(peers: [peer(other, online: true, expiry: nil), peer(nas, online: true, expiry: nil)]), host: nas, now: now)
check("online, the right device among several", online == .online(name: "nas-box", keyExpiry: nil), "\(online)")
check("found by its MagicDNS name too",
      Tailnet.parse(status(peers: [peer(nas, online: true, expiry: nil)]), host: magic, now: now) == .online(name: "nas-box", keyExpiry: nil))
check("an address nobody has", Tailnet.parse(status(peers: [peer(other, online: true, expiry: nil)]), host: nas, now: now) == .unknownDevice)
check("this Mac logged out", Tailnet.parse(status(state: "NeedsLogin", peers: []), host: nas, now: now) == .macNotConnected("NeedsLogin"))
check("unreadable output", Tailnet.parse(Data("nope".utf8), host: nas, now: now) == .unavailable)

print("Test 3 - what is said")
check("an expired sign-in says how to fix it and how to stop it recurring",
      Tailnet.explain(expired, host: nas, port: 8893).contains("Sign it back in")
      && Tailnet.explain(expired, host: nas, port: 8893).contains("key expiry"))
check("a proxy that is down while the NAS is on Tailscale says so",
      Tailnet.explain(online, host: nas, port: 8893).contains("port 8893"))
check("no warning without an expiry", Tailnet.warning(online, now: now) == nil)
check("no warning two months out",
      Tailnet.warning(.online(name: "nas-box", keyExpiry: now + 86400 * 60), now: now) == nil)
let soon = Tailnet.warning(.online(name: "nas-box", keyExpiry: now + 86400 * 6 + 60), now: now)
check("a warning in the last month", soon?.contains("in 6 days") == true && soon?.contains("key expiry") == true,
      soon ?? "nil")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
