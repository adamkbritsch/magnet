import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

print("Test 1 - filenames are made safe without losing the extension")
let s = DownloadManager.sanitised("Some/Book: A Story.epub")
check("path separators and colons removed", !s.contains("/") && !s.contains(":"), "got \(s)")
check("extension kept", s.hasSuffix(".epub"), "got \(s)")
check("empty name still yields something", !DownloadManager.sanitised("").isEmpty)
let long = DownloadManager.sanitised(String(repeating: "a", count: 400) + ".pdf")
check("over-long stem trimmed", long.count <= 190, "len=\(long.count)")
check("trimmed name keeps its extension", long.hasSuffix(".pdf"))

print("Test 2 - the SITE decides the folder, whatever the file is")
check("books site -> Books", DownloadManager.folder(for: "x.epub", siteCategory: .books) == "Books")
check("books site, odd file, still Books",
      DownloadManager.folder(for: "x.zip", siteCategory: .books) == "Books",
      "got \(DownloadManager.folder(for: "x.zip", siteCategory: .books))")
check("tv site -> TV", DownloadManager.folder(for: "x.mkv", siteCategory: .moviesAndTV) == "TV")
check("tv site, odd file, still TV",
      DownloadManager.folder(for: "x.rar", siteCategory: .moviesAndTV) == "TV")
check("games site -> Games", DownloadManager.folder(for: "x.iso", siteCategory: .games) == "Games")
check("games site, odd file, still Games",
      DownloadManager.folder(for: "x.pdf", siteCategory: .games) == "Games")

print("Test 3 - a multi-type site lets the file break the tie")
check("comic from a general site -> Books",
      DownloadManager.folder(for: "x.cbz", siteCategory: .everything) == "Books")
check("ebook from a general site -> Books",
      DownloadManager.folder(for: "x.epub", siteCategory: .everything) == "Books")
check("video from a general site -> TV",
      DownloadManager.folder(for: "x.mkv", siteCategory: .everything) == "TV")
check("installer from a general site -> Games",
      DownloadManager.folder(for: "x.iso", siteCategory: .everything) == "Games")
check("audio is not filed as a library -> Misc",
      DownloadManager.folder(for: "x.flac", siteCategory: .everything) == "Misc")
check("unknown file from a general site -> Misc",
      DownloadManager.folder(for: "x.qqq", siteCategory: .everything) == "Misc")
check("unclassified site behaves the same",
      DownloadManager.folder(for: "x.mkv", siteCategory: .other) == "TV")
check("no site at all still routes",
      DownloadManager.folder(for: "x.epub", siteCategory: nil) == "Books")

print("Test 4 - nothing is ever routed into a pipeline-owned folder")
// Folder names a media pipeline typically watches. A captured file landing in one
// would be imported, renamed and moved out from under us, so no routing rule may
// ever produce one of these.
let forbidden = ["Downloads", "Movies", "TV-Shows", "Audiobooks", "Pictures",
                 "Music", "Complete", "Incomplete"]
var routes = Set<String>()
for category in [BookmarkCategory.books, .moviesAndTV, .games, .everything, .other] {
    for ext in ["epub", "cbz", "mkv", "iso", "flac", "qqq", ""] {
        routes.insert(DownloadManager.folder(for: ext.isEmpty ? "x" : "x.\(ext)", siteCategory: category))
    }
}
check("every route is app-owned", routes.allSatisfy { !forbidden.contains($0) }, "routes=\(routes.sorted())")
check("routes are exactly the four expected", routes == ["Books", "TV", "Games", "Misc"],
      "got \(routes.sorted())")
check("archive root is not a watched folder", !forbidden.contains(DownloadManager.archiveRoot),
      "root=\(DownloadManager.archiveRoot)")

print("Test 4b - a response WebKit cannot display is NEVER rendered as text")
func d(_ canShow: Bool, _ attach: Bool, _ name: String, _ knownPage: Bool,
       _ trustedHost: Bool, _ clicked: Bool = true) -> DownloadManager.Disposition {
    DownloadManager.disposition(canShowMIMEType: canShow, isAttachment: attach,
                                filename: name, fromKnownSource: knownPage,
                                fileFromTrustedHost: trustedHost,
                                fileHost: "cdn.example", userInitiated: clicked)
}
func isRefusal(_ x: DownloadManager.Disposition) -> Bool {
    if case .refuse = x { return true }
    return false
}

check("unrenderable from an unknown page is still captured",
      d(false, false, "thing.bin", false, true) == .capture)
check("unrenderable from a known page is captured",
      d(false, false, "thing.bin", true, true) == .capture)
check("an explicit attachment is captured wherever it came from",
      d(true, true, "thing.bin", false, true) == .capture)
check("an ordinary page is left alone",
      d(true, false, "index.html", true, true) == .allow)
check("a guessable file on a known site is captured",
      d(true, false, "book.epub", true, true) == .capture)
check("the same file on an unknown site is not",
      d(true, false, "book.epub", false, true) == .allow)

print("Test 4c - a decoy download cannot put an installer on this Mac")
// The bug: a fake download button among the real ones served an installer from the
// advert's own host, and it was captured and filed like anything else.
check("an installer from an UNRELATED host is refused",
      isRefusal(d(false, false, "setup.exe", true, false)),
      "\(d(false, false, "setup.exe", true, false))")
check("even when the server calls it an attachment",
      isRefusal(d(true, true, "installer.msi", true, false)))
check("and for every shape of the same thing",
      ["setup.exe", "a.msi", "b.dmg", "c.pkg", "d.apk", "e.scr", "f.bat", "g.jar",
       "h.ps1", "i.vbs", "j.deb"].allSatisfy { isRefusal(d(false, false, $0, true, false)) })
// The repack sites hand you an installer on purpose, and that must keep working.
check("BUT an installer from the site you are on is still captured",
      d(false, false, "setup.exe", true, true) == .capture)
check("and from a bookmarked site's own host too",
      d(true, true, "game-installer.exe", true, true) == .capture)
// Torrent files and books routinely come from a CDN. Refusing those would break more
// than it protects, and they do not run.
// These used to be allowed through on the grounds that they do not run. They still
// do not run, but they still arrive unasked, and a file host that is genuinely used
// is named in the refusal and added once in Settings.
check("a .torrent from a third-party host is refused until its host is allowed",
      isRefusal(d(false, false, "thing.torrent", true, false)))
check("an ebook from one likewise",
      isRefusal(d(false, false, "book.epub", true, false)))

print("Test 4d - a click is no longer evidence of anything")
// The escalation: the hijack listens for the first click ANYWHERE and starts the
// download from it, so "the user clicked" is true of the fake ones too. Scoping the
// refusal to executables was not enough, because the payload does not have to be one.
check("a zip from an unrelated host is refused even after a click",
      isRefusal(d(false, false, "totally-normal.zip", true, false, true)))
check("so is a rar", isRefusal(d(false, false, "part1.rar", true, false, true)))
check("and an attachment it calls a document",
      isRefusal(d(true, true, "invoice.pdf", true, false, true)))
check("a download nobody started at all is refused",
      isRefusal(d(false, false, "thing.zip", true, false, false)))
// The escape hatch has to actually work, or repack sites stop working.
check("but a trusted host needs no click",
      d(false, false, "thing.zip", true, true, false) == .capture)
check("and a trusted host may hand over anything",
      d(false, false, "setup.exe", true, true, true) == .capture)

print("Test 4d2 - a download nobody started is refused")
check("an untrusted host offering a file with no click is refused",
      isRefusal(d(false, false, "thing.zip", true, false, false)))
// Used to be captured, on the theory that a click meant you asked for it. It does
// not: the hijack fires off a click you meant for something else entirely.
check("the same file after a click is STILL refused",
      isRefusal(d(false, false, "thing.zip", true, false, true)))
check("a click is not required from a host you trust",
      d(false, false, "thing.zip", true, true, false) == .capture)

print("Test 4f - the payload that actually got through")
// OperaSetup.zip, five copies under Games, identical size and all different hashes.
// Every origin rule missed it, and this is why:
check("it is not an executable by extension, so that rule never fired",
      !DownloadManager.isExecutable("OperaSetup.zip"))
check("and .zip is filed as software, which is how it reached Games",
      DownloadManager.kind(of: "OperaSetup.zip") == .software)
// The decisive one: served from the SAME domain as the site being read, which is a
// trusted host under any rule drawn from where a file came from. No origin test can
// separate that from a real download, which is why approval moved to a dialog.
check("from the page's own domain it passes every origin check",
      d(false, false, "OperaSetup.zip", true, true) == .capture,
      "an origin rule cannot catch this — the dialog is the guard")
check("only from a third-party host does an origin rule catch it",
      isRefusal(d(false, false, "OperaSetup.zip", true, false)))

print("Test 4e - only a real magnet reaches the torrent client")
func mag(_ s: String) -> Bool { MagnetSender.isValidMagnet(URL(string: s)!) }
check("a v1 hex info hash is real",
      mag("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Thing"))
check("uppercase is the same hash",
      mag("magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567"))
check("base32 is the other spelling",
      mag("magnet:?xt=urn:btih:abcdefghijklmnopqrstuvwxyz234567"))
check("so is a v2 multihash",
      mag("magnet:?xt=urn:btmh:1220caf1e1e1caf1e1e1caf1e1e1caf1e1e1caf1e1e1caf1e1e1caf1e1e1caf1e1e1"))
check("the hash can sit after other fields",
      mag("magnet:?dn=Thing&tr=http%3A%2F%2Ftracker.example&xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
// A decoy only has to wear the scheme, and the app hands anything wearing it to the
// client. A torrent client is a poor place to find out it was an advert.
check("a magnet with NO hash is refused", !mag("magnet:?dn=Free+Download"))
check("a magnet with a truncated hash is refused",
      !mag("magnet:?xt=urn:btih:0123456789abcdef"))
check("a magnet whose hash is not hex is refused",
      !mag("magnet:?xt=urn:btih:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
check("a magnet carrying a URL instead of a hash is refused",
      !mag("magnet:?xt=http://ad.example/track"))
check("something that is not a magnet at all is refused",
      !mag("https://ad.example/download"))
// A .torrent link is an ordinary URL the client fetches for itself. Checking one for
// an info hash rejected every real one -- the guard above, applied where it does not
// belong. It only ever applies to the magnet scheme.
check("a .torrent link is NOT judged as a magnet",
      !mag("https://tracker.example/download/123/thing.torrent"),
      "the validator answers for magnets only; the caller must not ask about .torrent")

print("Test 4g - a frame does not get to start a download")
// Measured in a live WKWebView: an iframe navigating to an attachment reaches the
// response step with isForMainFrame false and becomes a WKDownload like any other --
// and the page URL handed in is the MAIN page, so the frame's drop was judged against
// an origin that had nothing to do with it.
func f(_ canShow: Bool, _ attach: Bool, _ mainFrame: Bool) -> DownloadManager.Disposition {
    DownloadManager.disposition(canShowMIMEType: canShow, isAttachment: attach,
                                filename: "thing.zip", fromKnownSource: true,
                                fileFromTrustedHost: true, fileHost: "cdn.example",
                                userInitiated: true, isForMainFrame: mainFrame)
}
check("a frame offering a FILE is refused", isRefusal(f(false, false, false)))
check("the main frame offering the same file is taken", f(false, false, true) == .capture)
// The order of these two checks is the bug that stranded every Cloudflare challenge.
// Asked before "is this even a download", it cancelled every subframe response there
// is -- so no iframe could load, including the one holding the challenge.
check("A FRAME LOADING AN ORDINARY PAGE IS NEVER TOUCHED",
      DownloadManager.disposition(canShowMIMEType: true, isAttachment: false,
                                  filename: "challenge-platform", fromKnownSource: true,
                                  fileFromTrustedHost: true, fileHost: "1337x.to",
                                  userInitiated: false, isForMainFrame: false) == .allow,
      "an iframe must be able to load HTML, or Cloudflare's challenge cannot appear")
check("and a frame never triggers a capture by guessing at a filename",
      f(true, false, false) == .allow, "\(f(true, false, false))")
check("nor is a frame loading renderable content from anywhere",
      DownloadManager.disposition(canShowMIMEType: true, isAttachment: false,
                                  filename: "challenge", fromKnownSource: false,
                                  fileFromTrustedHost: false, fileHost: "challenges.cloudflare.com",
                                  userInitiated: false, isForMainFrame: false) == .allow)

print("Test 5 - a colliding destination gets a fresh name")
let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("x1337-dl-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let first = dir.appendingPathComponent("book.epub")
check("free path returned unchanged", DownloadManager.unique(first) == first)
FileManager.default.createFile(atPath: first.path, contents: Data("x".utf8))
let second = DownloadManager.unique(first)
check("collision avoided", second != first, "got \(second.lastPathComponent)")
check("collision keeps the extension", second.pathExtension == "epub")
FileManager.default.createFile(atPath: second.path, contents: Data("x".utf8))
let third = DownloadManager.unique(first)
check("second collision avoided too", third != first && third != second)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
