import Foundation

// window.open was the one redirect technique of twelve that still worked.
//
// The popup itself was dropped, as designed -- and then the URL was loaded into the
// main view instead, arriving as an ordinary navigation nobody had judged. The gate
// was `mayBeDownload`, which answered yes to ANY http address opened from a page in
// the bar. That is every redirect advert there is.
//
// The rule now: a popup is followed only when it points at a FILE. An advert points
// at a page. Measured against the real policy in a live WKWebView -- all twelve
// techniques blocked -- and pinned here in both directions, because a fix that also
// broke "download link opens in a new tab" would be a different bug, not a fix.
var failures = 0
func check(_ n: String, _ c: Bool, _ d: @autoclosure () -> String = "") {
    if c { print("  PASS  \(n)") } else { failures += 1; print("  FAIL  \(n)   \(d())") }
}
let page = URL(string: "https://tracker.example/browse")!
MainActor.assumeIsolated {
    DownloadManager.shared.knownSources = { ["tracker.example"] }
    let m = DownloadManager.shared
    @MainActor func may(_ s: String) -> Bool { m.mayBeDownload(URL(string: s)!, pageURL: page) }

    print("A popup to a FILE is still followed")
    check("a .torrent in a new tab", may("https://tracker.example/dl/123/thing.torrent"))
    check("a .zip from a file host", may("https://filehost.example/get/pack.zip"))
    check("a .rar part", may("https://filehost.example/a/part1.rar"))
    check("an .epub", may("https://cdn.example/books/x.epub"))
    check("an .mkv", may("https://cdn.example/v/film.mkv"))

    print("\nA popup to a PAGE is not")
    check("the bare advert domain", !may("https://junk.example/"))
    check("a tracking path", !may("https://junk.example/click?id=99"))
    check("an html page", !may("https://junk.example/offer.html"))
    check("a php redirector", !may("https://junk.example/go.php?u=x"))
    check("and nothing at all from a page not in the bar",
          !m.mayBeDownload(URL(string: "https://filehost.example/get/pack.zip")!,
                           pageURL: URL(string: "https://stranger.example/")!))

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
