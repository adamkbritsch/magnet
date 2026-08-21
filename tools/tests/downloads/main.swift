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
check("a .torrent from a third-party host still works",
      d(false, false, "thing.torrent", true, false) == .capture)
check("so does an ebook from one",
      d(false, false, "book.epub", true, false) == .capture)

print("Test 4d - a download nobody started is refused")
check("an untrusted host offering a file with no click is refused",
      isRefusal(d(false, false, "thing.zip", true, false, false)))
check("the same file after a click is taken",
      d(false, false, "thing.zip", true, false, true) == .capture)
check("a click is not required from a host you trust",
      d(false, false, "thing.zip", true, true, false) == .capture)

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
