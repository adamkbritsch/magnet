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
