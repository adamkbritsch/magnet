import Foundation

/// Which network this Mac is attached to, identified without asking for a permission.
///
/// The Wi-Fi name is the obvious key, and macOS will not give it up. Every route to
/// it -- CoreWLAN, `networksetup -getairportnetwork`, `ipconfig getsummary`,
/// `system_profiler SPAirPortDataType` -- answers `<redacted>` unless the app holds
/// Location Services authorization. Measured on macOS 26.5.1; `networksetup` does not
/// even admit to being redacted, it claims the Mac is not on a network at all.
///
/// The router's MAC address identifies the network just as well: it is unique to that
/// piece of hardware, it is stable, and reading it costs no prompt and no location
/// indicator in the menu bar. Two SSIDs on one router (a 2.4GHz and a 5GHz band, say)
/// collapse to a single entry, which is the right answer here anyway -- same router,
/// same upstream, same idea about what it will let through.
enum NetworkIdentity {
    struct Network: Equatable, Sendable {
        /// Stable key for remembering. The gateway's MAC address.
        let key: String
        /// Something a person can recognise, for the settings pane.
        let label: String
    }

    /// Runs four short subprocesses, so roughly a quarter of a second. Never call it
    /// on the main actor -- the launch path already has a window to put on screen.
    static func current() -> Network? {
        let route = run("/sbin/route", ["-n", "get", "default"])
        guard let gateway = parseGateway(route) else { return nil }
        guard let mac = gatewayMAC(gateway) else { return nil }
        return Network(key: mac, label: label(gateway: gateway,
                                              interface: parseInterface(route)))
    }

    // MARK: - Parsing, kept separate from the commands so it can be tested

    /// `route -n get default` prints an indented `gateway: 192.0.2.1` line.
    static func parseGateway(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "gateway" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The same `route` output names the interface carrying the default route, which
    /// is the only one whose DHCP lease describes the network in use.
    static func parseInterface(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `arp -n 192.0.2.1` prints `? (192.0.2.1) at a1:b:22:33:44:55 on en0 ifscope [ethernet]`,
    /// or `no entry` when the address has not been resolved yet.
    static func parseMAC(_ output: String) -> String? {
        guard let range = output.range(of: " at ") else { return nil }
        let rest = output[range.upperBound...]
        let token = rest.split(separator: " ").first.map(String.init) ?? ""
        let octets = token.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        // arp does not zero-pad, so the same address reads as a1:b:22:... here and
        // a1:0b:22:... everywhere else. Two spellings of one network would be two
        // entries, and the second one would look like a network it had never seen.
        var padded: [String] = []
        for octet in octets {
            let hex = octet.lowercased()
            guard hex.count == 1 || hex.count == 2,
                  hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            padded.append(hex.count == 1 ? "0" + hex : hex)
        }
        return padded.joined(separator: ":")
    }

    /// `ipconfig getpacket en0` carries the DHCP lease, and a lot of networks name
    /// themselves in it -- a campus or office domain is far more recognisable than an
    /// address. Falls back to the gateway itself, which at least differs per network.
    static func parseDHCPDomain(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The trailing space is load-bearing: it excludes `domain_name_server`,
            // which is a list of addresses and would make a terrible label.
            guard trimmed.hasPrefix("domain_name ") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t{}\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - The commands themselves

    private static func gatewayMAC(_ gateway: String) -> String? {
        // A gateway that has not been ARPed yet has no entry, and the lookup that
        // populates it is the one that just failed. One retry after a ping covers it.
        if let mac = parseMAC(run("/usr/sbin/arp", ["-n", gateway])) { return mac }
        _ = run("/sbin/ping", ["-c", "1", "-t", "1", gateway])
        return parseMAC(run("/usr/sbin/arp", ["-n", gateway]))
    }

    private static func label(gateway: String, interface: String?) -> String {
        guard let interface else { return gateway }
        let lease = run("/usr/sbin/ipconfig", ["getpacket", interface])
        return parseDHCPDomain(lease) ?? gateway
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
