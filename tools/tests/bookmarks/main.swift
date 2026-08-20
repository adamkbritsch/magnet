import Foundation

// BookmarkStore ships with nothing seeded: no sites, no Firefox import.
let KEYS = ["bookmarks.hidden", "bookmarks.pinned", "bookmarks.extra",
            "bookmarks.folderName", "bookmarks.infraHosts"]
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}
@MainActor func reset() {
    for k in KEYS { UserDefaults.standard.removeObject(forKey: k) }
    AppSettings.shared.resetAll()
}

MainActor.assumeIsolated {
    print("Test 1 - a fresh install has nothing in it")
    reset()
    let s = BookmarkStore()
    check("no manually added sites", s.extras.isEmpty, "got \(s.extras.map(\.url.absoluteString))")
    check("nothing visible", s.visible.isEmpty)
    check("nothing hidden", s.hiddenBookmarks.isEmpty)
    check("nothing pinned", s.pinnedFirst.isEmpty)

    print("Test 2 - no Firefox folder configured means no import, and no error")
    s.refresh(force: true)
    check("no bookmarks imported", s.bookmarks.isEmpty)
    check("not reported as a failure", s.lastError == nil, "got \(s.lastError ?? "nil")")
    check("folder not claimed to be found", !s.folderFound)

    print("Test 3 - adding and removing a site")
    let url = URL(string: "https://example.org/")!
    check("added", s.addExtra(title: "Example", url: url))
    check("shows in the bar", s.visible.contains { $0.url == url })
    check("the same site is not added twice", !s.addExtra(title: "Example", url: url))
    check("still one entry", s.extras.count == 1, "got \(s.extras.count)")
    check("survives a reload", { let t = BookmarkStore(); return t.extras.count == 1 }())

    print("Test 4 - removing a site takes its hide and pin with it")
    let bm = s.extras[0]
    s.setHidden(bm, true)
    s.setPinned(bm, true)
    check("hidden and pinned first", s.hidden.contains(bm.id) && s.isPinned(bm))
    s.removeExtra(bm)
    check("gone from the list", s.extras.isEmpty)
    check("stale hide cleared", !s.hidden.contains(bm.id), "hidden=\(s.hidden)")
    check("stale pin cleared", !s.isPinned(bm), "pinned=\(s.pinnedFirst)")

    print("Test 5 - a title that says nothing still yields a usable chip label")
    reset()
    let t = BookmarkStore()
    t.addExtra(title: "", url: URL(string: "https://the-audiobook-bay.se/")!)
    check("falls back to the domain", !(t.extras.first?.chipLabel.isEmpty ?? true),
          "got \(t.extras.first?.chipLabel ?? "nil")")

    reset()
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
