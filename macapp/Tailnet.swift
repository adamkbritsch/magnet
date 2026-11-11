import Foundation

/// What this Mac's own Tailscale knows about the device behind the proxy address.
///
/// When the proxy's address is a Tailscale one and it stops answering, "not
/// answering" is not much to go on: the device's sign-in may have expired (Tailscale
/// keys do, every 180 days unless key expiry is turned off), it may be offline, or
/// Tailscale may be off on this Mac. The `tailscale` command on this Mac says which,
/// and the same reading warns of an expiry before it happens.
enum TailnetReport: Equatable {
    /// The proxy address is not a Tailscale address; nothing to say.
    case notTailnet
    /// No `tailscale` command here, or it did not answer.
    case unavailable
    /// Tailscale on this Mac is not connected (its backend state).
    case macNotConnected(String)
    /// No device on the tailnet has that address.
    case unknownDevice
    /// The device's sign-in has expired: it is off the tailnet until it signs in again.
    case expired(name: String, at: Date?)
    /// The device is on the tailnet's list but not connected.
    case offline(name: String, lastSeen: Date?)
    /// Connected. `keyExpiry` is nil when key expiry is off.
    case online(name: String, keyExpiry: Date?)
}

enum Tailnet {
    /// Within this many days of a sign-in expiring, it is worth a warning.
    static let warnDays = 30

    /// Tailscale's address ranges (100.64/10, and fd7a:115c:a1e0::/48) and its
    /// MagicDNS names.
    static func isTailnetHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] ."))
        if h.hasSuffix(".ts.net") { return true }
        if h.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = h.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ Int($0) != nil }) else { return false }
        return a == 100 && (64...127).contains(b)
    }

    /// The reading for `host`, from the `tailscale status --json` this Mac gives.
    static func report(for host: String) async -> TailnetReport {
        guard isTailnetHost(host) else { return .notTailnet }
        guard let data = await statusJSON() else { return .unavailable }
        return parse(data, host: host)
    }

    static func parse(_ data: Data, host: String, now: Date = Date()) -> TailnetReport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        let state = root["BackendState"] as? String ?? ""
        if state != "Running" { return .macNotConnected(state.isEmpty ? "unknown" : state) }
        let want = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] ."))
        let peers = (root["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        guard let peer = peers.first(where: { p in
            let ips = (p["TailscaleIPs"] as? [String] ?? []).map { $0.lowercased() }
            let dns = (p["DNSName"] as? String ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let name = (p["HostName"] as? String ?? "").lowercased()
            return ips.contains(want) || dns == want || (!name.isEmpty && name == want)
                || (!dns.isEmpty && dns.split(separator: ".").first.map(String.init) == want)
        }) else { return .unknownDevice }
        let name = peer["HostName"] as? String ?? want
        let expiry = date(peer["KeyExpiry"])
        if (peer["Expired"] as? Bool) == true || (expiry.map { $0 <= now } ?? false) {
            return .expired(name: name, at: expiry)
        }
        if (peer["Online"] as? Bool) != true {
            return .offline(name: name, lastSeen: date(peer["LastSeen"]))
        }
        return .online(name: name, keyExpiry: expiry)
    }

    /// Why the proxy is not answering, and what to do, for the offline screen.
    static func explain(_ report: TailnetReport, host: String, port: UInt16) -> String {
        let base = "The NAS proxy at \(host):\(port) is not answering. Sites load only through it."
        switch report {
        case .notTailnet, .unavailable:
            return base
        case .macNotConnected(let state):
            return "Tailscale is not connected on this Mac (\(state)), so the NAS's Tailscale address "
                + "cannot be reached. Turn Tailscale on, then Try Again."
        case .unknownDevice:
            return base + " No device on your tailnet has that address: check the address in "
                + "Settings \u{2192} Connection."
        case .expired(let name, let at):
            return "The NAS's Tailscale sign-in expired\(at.map { " on " + day($0) } ?? ""), so \(name) is off "
                + "your tailnet and its proxy cannot be reached. Sign it back in -- on the NAS, "
                + "`tailscale status` shows the sign-in link -- then Try Again. Turn off key expiry for "
                + "\(name) in the Tailscale admin console so it does not expire again."
        case .offline(let name, let seen):
            return "\(name) is offline on Tailscale\(seen.map { " (last seen " + ago($0) + ")" } ?? ""). "
                + "The NAS may be down or busy, or its Tailscale has stopped. Try Again once it is back."
        case .online(let name, _):
            return "\(name) is on Tailscale, but nothing answers on port \(port): the proxy itself may "
                + "have stopped on the NAS."
        }
    }

    /// A warning worth showing while everything still works: the sign-in expires soon.
    static func warning(_ report: TailnetReport, now: Date = Date()) -> String? {
        guard case .online(let name, let expiry?) = report else { return nil }
        let days = Int(expiry.timeIntervalSince(now) / 86400)
        guard days < warnDays else { return nil }
        return "The NAS's Tailscale sign-in expires \(days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days") "
            + "(\(day(expiry))). Then its proxy stops answering. Turn off key expiry for \(name) in the "
            + "Tailscale admin console."
    }

    // MARK: - The command

    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    /// `tailscale status --json`, or nil. Never longer than a few seconds.
    private static func statusJSON() async -> Data? {
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = ["status", "--json"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0 && !data.isEmpty ? data : nil)
            }
        }
    }

    // MARK: - Dates

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.hasPrefix("0001-") else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    private static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
