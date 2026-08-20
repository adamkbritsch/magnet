import AppKit
import Foundation
import WebKit

/// Captures direct downloads from any site the app knows about and files them into
/// an archive on the NAS.
///
/// This is deliberately not wired to one site. A page counts as a download source if
/// it is in the bookmark bar -- which is read live from Firefox -- so a new site is
/// covered the moment it is bookmarked, with no code change. Where a file lands is
/// decided by what the file IS, falling back to what the site is for.
///
/// Downloads land on the Mac first and move to the NAS once whole: a download writes
/// incrementally, and doing that over SMB is slow and leaves half-written files when
/// the link drops.
///
/// The share is mounted when a download STARTS -- not when a page opens -- so the NAS
/// is only ever touched because something is genuinely on its way in. A failed mount
/// notifies once and then stops being retried for the session; clicking a chip in the
/// bar re-arms it.
///
/// **Point the archive root at a folder nothing else manages.** Everything lands
/// under one configurable root rather than beside an existing media library: if the
/// root is a directory a media pipeline watches -- an *arr import folder, a music
/// library -- captured files get picked up, renamed and moved out from under you.
/// The default root is a folder of its own for exactly that reason.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    /// SMB coordinates of the share holding the archive. Empty until configured, in
    /// which case downloads simply stay on this Mac.
    nonisolated static var share: String { Config.nasShare }
    nonisolated static var nasHost: String { Config.nasHost }
    nonisolated static var nasUser: String { Config.nasUser }

    /// Root folder on the share that this app owns.
    nonisolated static var archiveRoot: String { Config.archiveRoot }

    /// Local staging. Mirrors the archive layout, so filing a file is a move to the
    /// same relative path and needs no second mapping.
    nonisolated static var localRoot: URL { Config.localRoot }

    /// text, isError
    var onMessage: ((String, Bool) -> Void)?

    /// Supplied by the UI, so this stays decoupled from the bookmark store. Every
    /// site in the bar is a download source -- this is what makes future sites work
    /// without touching code.
    var knownSources: () -> Set<String> = { [] }

    private var names: [WKDownload: String] = [:]
    private var pages: [WKDownload: URL] = [:]
    private var mounting = false

    /// Set when a mount attempt fails. The app then stops trying for the rest of the
    /// session rather than retrying on every navigation and every finished download.
    /// Clicking a chip in the bar is the ONE thing that clears it -- an in-page
    /// navigation does not count, because the point is that a deliberate act asks
    /// for another try.
    ///
    /// In memory on purpose: "this session" ends when the app quits.
    private var mountBlocked = false

    private override init() {
        super.init()
        watchForDisconnect()
    }

    // MARK: - What a file is

    enum FileKind {
        case comic, ebook, video, audio, software, unknown
    }

    nonisolated static func kind(of filename: String) -> FileKind {
        switch (filename as NSString).pathExtension.lowercased() {
        case "cbz", "cbr", "cb7", "cbt":
            return .comic
        case "epub", "mobi", "azw", "azw3", "fb2", "djvu", "djv", "lit", "prc", "pdf":
            return .ebook
        case "mkv", "mp4", "avi", "m4v", "mov", "webm", "ts", "m2ts", "wmv", "mpg", "mpeg":
            return .video
        case "flac", "mp3", "m4a", "m4b", "aac", "ogg", "opus", "wav", "wv", "ape":
            return .audio
        case "iso", "exe", "msi", "dmg", "pkg", "zip", "rar", "7z", "tar", "gz", "bin", "apk":
            return .software
        default:
            return .unknown
        }
    }

    /// Which folder a download belongs in, as a path relative to both the staging
    /// root and the archive root.
    ///
    /// What the SITE is decides it. A site in the bar is already classified for the
    /// bookmark bar's own grouping, so the same answer routes its downloads and
    /// there is nothing extra to maintain. Only when the site covers several types
    /// (or nobody has classified it) does the file's own extension break the tie.
    nonisolated static func folder(for filename: String, siteCategory: BookmarkCategory?) -> String {
        switch siteCategory {
        case .books, .moviesAndTV, .games:
            return Config.categoryFolder(siteCategory!.rawValue)
        default:
            // The site covers several types, so let the file break the tie.
            let implied: BookmarkCategory
            switch kind(of: filename) {
            case .comic, .ebook: implied = .books
            case .video:         implied = .moviesAndTV
            case .software:      implied = .games
            // Audio is left unsorted rather than filed as a library: a music
            // collection is almost always managed by something else.
            case .audio:         implied = .other
            case .unknown:       implied = .other
            }
            return Config.categoryFolder(implied.rawValue)
        }
    }

    // MARK: - Capture decision

    /// Whether a response should be pulled out of the web view and written to disk.
    ///
    /// Keyed on the PAGE, not the file's host: sites routinely hand the actual bytes
    /// to partner or CDN hosts on unrelated domains, so matching the response host
    /// would miss most real downloads.
    func shouldCapture(_ response: WKNavigationResponse, pageURL: URL?) -> Bool {
        guard let pageURL, isKnownSource(pageURL) else { return false }
        if !response.canShowMIMEType { return true }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return true
        }
        return Self.kind(of: response.response.url?.lastPathComponent ?? "") != .unknown
    }

    /// A link opened from a known source that could plausibly be a file.
    /// Intentionally loose -- the real gate is `shouldCapture`, which sees the
    /// response headers; this only decides whether a new-tab link is worth following.
    func mayBeDownload(_ url: URL, pageURL: URL?) -> Bool {
        guard let pageURL, isKnownSource(pageURL) else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return true
    }

    /// Any site in the bar, or any mirror of one.
    func isKnownSource(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let domains = knownSources()
        guard !domains.isEmpty else { return false }
        if domains.contains(registrableDomain(host)) { return true }
        if let set = MirrorDirectory.shared.set(owning: url) {
            return set.candidates.contains { candidate in
                candidate.host.map { domains.contains(registrableDomain($0)) } ?? false
            }
        }
        return false
    }

    // MARK: - Mounting

    /// A deliberate click on a bar chip. This only lifts a mount block -- it does
    /// not mount anything. The volume is wanted when a file is actually coming down,
    /// not because a page was opened, so the attempt itself waits for a download.
    func userOpenedFromBar(_ url: URL) {
        guard isKnownSource(url) else { return }
        mountBlocked = false
    }

    /// Only fires while a download is actually in flight: a volume dropping out when
    /// nothing is being written is not this app's business.
    private func watchForDisconnect() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            let path = (note.userInfo?["NSDevicePath"] as? String).map { URL(fileURLWithPath: $0) }
            guard (url ?? path)?.lastPathComponent == Self.share else { return }
            Task { @MainActor in
                guard let self, !self.names.isEmpty else { return }
                self.mountAndSweep()
            }
        }
    }

    nonisolated static func existingMount() -> URL? {
        guard !share.isEmpty else { return nil }
        let path = URL(fileURLWithPath: "/Volumes/\(share)")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// osascript rather than mount_smbfs: /Volumes is root-owned so creating the
    /// mountpoint directly needs sudo, whereas NetAuth makes it and takes the
    /// password from the login Keychain, which keeps this non-interactive. Run as a
    /// subprocess rather than NSAppleScript because this is called off the main
    /// thread and NSAppleScript is not thread-safe.
    nonisolated static func ensureMounted() -> URL? {
        if let up = existingMount() { return up }
        // Nothing to mount until the share is described.
        guard Config.nasConfigured else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "mount volume \"smb://\(nasUser)@\(nasHost)/\(share)\""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        return existingMount()
    }

    /// Gets the volume if it is already up, otherwise attempts one mount -- unless a
    /// previous attempt failed this session, in which case it does nothing at all.
    ///
    /// `silent` lets a caller own the wording so one action never produces two
    /// toasts; the block flag is still set either way, because that is state rather
    /// than messaging.
    private func mountAndSweep(silent: Bool = false, completion: ((URL?) -> Void)? = nil) {
        if let up = Self.existingMount() {
            sweep(volume: up, silent: silent, completion: completion)
            return
        }
        guard !mountBlocked, !mounting else { completion?(nil); return }

        mounting = true
        DispatchQueue.global(qos: .utility).async {
            let volume = Self.ensureMounted()
            let moved = volume == nil ? 0 : Self.sweepPending()
            DispatchQueue.main.async {
                self.mounting = false
                if volume == nil {
                    self.mountBlocked = true
                    if !silent {
                        self.announce("Couldn't reach \(Self.share) \u{2014} files stay on this Mac. "
                                      + "Open a site from the bar to try again.", isError: true)

                    }
                } else if moved > 0, !silent {
                    self.announceMoved(moved)
                }
                completion?(volume)
            }
        }
    }

    private func sweep(volume: URL, silent: Bool, completion: ((URL?) -> Void)?) {
        DispatchQueue.global(qos: .utility).async {
            let moved = Self.sweepPending()
            DispatchQueue.main.async {
                if moved > 0, !silent { self.announceMoved(moved) }
                completion?(volume)
            }
        }
    }

    private func announceMoved(_ count: Int) {
        announce("Filed \(count) file\(count == 1 ? "" : "s") to \(Self.share)", isError: false)
    }

    // MARK: - Filing

    /// Everything staged locally, with the relative path it should keep on the NAS.
    nonisolated static func pendingFiles() -> [(file: URL, relative: String)] {
        let root = localRoot
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, String)] = []
        for case let url as URL in walker {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative != url.path else { continue }
            out.append((url, relative))
        }
        return out
    }

    /// Moves everything staged on the Mac to the NAS. Returns how many made it.
    @discardableResult
    nonisolated static func sweepPending() -> Int {
        guard let volume = existingMount() else { return 0 }
        let root = volume.appendingPathComponent(archiveRoot)
        return pendingFiles().reduce(into: 0) { count, entry in
            if move(entry.file, toRelative: entry.relative, on: root) { count += 1 }
        }
    }

    nonisolated static func move(_ file: URL, toRelative relative: String, on root: URL) -> Bool {
        let target = root.appendingPathComponent(relative)
        let dir = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: unique(target))
            return true
        } catch {
            return false
        }
    }

    nonisolated static func localDestination(for filename: String, siteCategory: BookmarkCategory?) -> URL? {
        let name = sanitised(filename)
        let dir = localRoot.appendingPathComponent(folder(for: name, siteCategory: siteCategory))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return unique(dir.appendingPathComponent(name))
    }

    /// Filenames from these sites are long and carry punctuation that is fine on
    /// ext4 but not over SMB, and a path separator would escape the folder entirely.
    nonisolated static func sanitised(_ filename: String) -> String {
        var name = filename
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "download" }
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        if stem.isEmpty { stem = "download" }
        if stem.count > 180 { stem = String(stem.prefix(180)) }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// WKDownload refuses a destination that already exists.
    nonisolated static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for n in 2...999 {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }

    /// Records which page a download came from, so its destination can fall back to
    /// what that site is for when the filename says nothing.
    func attach(_ download: WKDownload, page: URL?) {
        download.delegate = self
        if let page { pages[download] = page }
    }

    fileprivate func announce(_ text: String, isError: Bool) {
        onMessage?(text, isError)
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        names[download] = suggestedFilename
        let category = pages[download].map { Categoriser.category(for: $0) }
        // Local, so this never blocks on a mount and never half-writes over SMB.
        let target = Self.localDestination(for: suggestedFilename, siteCategory: category)
        if target == nil {
            announce("Couldn't create the local library folder \u{2014} download cancelled", isError: true)
        } else {
            announce("Downloading \(suggestedFilename)\u{2026}", isError: false)
            // THIS is the cue to get the volume ready: a file is now actually coming
            // down. Silent, and in the background, so it neither delays the download
            // nor talks over it -- the one message the user needs comes at the end,
            // saying where the file actually went.
            mountAndSweep(silent: true)
        }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let name = names.removeValue(forKey: download) ?? "File"
        let category = pages.removeValue(forKey: download).map { Categoriser.category(for: $0) }
        let folder = Self.folder(for: name, siteCategory: category)
        // Silent, so the one message the user sees says where the file actually is.
        mountAndSweep(silent: true) { volume in
            if volume != nil {
                self.announce("Saved \(name) to \(Self.share)/\(Self.archiveRoot)/\(folder)", isError: false)
            } else {
                let where_ = Self.share.isEmpty ? "no archive configured" : "\(Self.share) unreachable"
                self.announce("Saved \(name) to this Mac \u{2014} \(where_)", isError: false)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let name = names.removeValue(forKey: download) ?? "Download"
        pages.removeValue(forKey: download)
        announce("\(name) failed: \(error.localizedDescription)", isError: true)
    }
}
