import Foundation

/// A record, kept on this Mac only, of what the browser decided about each page load.
///
/// Most of what the browser refuses, it refuses silently — a redirect nobody asked for
/// is not worth a notice — so when a site that works in another browser simply stops,
/// nothing on screen says which step died or why. This does. Each main-frame decision,
/// response and failure is one line: the time, the event, and the addresses involved.
///
/// Addresses are logged as scheme, host and path only — no query string, no fragment,
/// and never a form's contents — so a search or a sign-in leaves nothing in it worth
/// reading. The file is capped and trimmed from the front.
enum NavigationLog {
    private static let queue = DispatchQueue(label: "magnet.navigation-log", qos: .utility)
    private static let cap = 2_000_000

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Magnet", isDirectory: true)
            .appendingPathComponent("navigation.log")
    }

    /// `scheme://host/path`, nothing more.
    static func describe(_ url: URL?) -> String {
        guard let url else { return "-" }
        guard let scheme = url.scheme, let host = url.host else {
            return url.scheme.map { "\($0):…" } ?? "-"
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(url.path.isEmpty ? "/" : url.path)"
    }

    static func write(_ event: String, _ detail: String) {
        let line = "\(stamp()) \(event.padding(toLength: 9, withPad: " ", startingAt: 0)) \(detail)\n"
        queue.async {
            let file = fileURL
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if size > cap { trim(file) }
            append(line, to: file)
        }
    }

    private static func append(_ line: String, to file: URL) {
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// Keeps the newer half, cut at a line boundary.
    private static func trim(_ file: URL) {
        guard let data = try? Data(contentsOf: file), data.count > cap / 2 else { return }
        var tail = data.suffix(cap / 2)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: file)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
