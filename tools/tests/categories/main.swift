import AppKit
import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}
func bm(_ s: String) -> Bookmark { Bookmark(title: s, url: URL(string: s)!) }

MainActor.assumeIsolated {
    print("Test 1 - sites land in the right group")
    let cases: [(String, BookmarkCategory)] = [
        ("https://1337x.to/home/", .everything),
        ("https://rutracker.org/", .everything),
        ("https://fmhy.net/torrenting", .everything),
        ("https://yts.mx/", .moviesAndTV),
        ("https://eztvx.to/", .moviesAndTV),
        ("https://nyaa.si/", .moviesAndTV),
        ("https://dodi-repacks.site/", .games),
        ("https://fitgirl-repacks.site/", .games),
        ("https://steamrip.com/", .games),
        ("https://annas-archive.pk/", .books),
        ("https://annas-archive.gl/", .books),
        ("https://theaudiobookbay.se/", .books),
    ]
    for (url, expected) in cases {
        let got = Categoriser.category(for: URL(string: url)!)
        check("\(URL(string: url)!.host!) -> \(expected.label)", got == expected, "got \(got.label)")
    }

    print("Test 2 - an unclassified site is not silently dropped")
    check("unknown host lands in Other",
          Categoriser.category(for: URL(string: "https://something-new.example/")!) == .other)

    print("Test 3 - a mirror inherits its set's category")
    // x1337x.cc is not in the table, but the curated 1337x set knows it.
    check("1337x mirror classified via its set",
          Categoriser.category(for: URL(string: "https://x1337x.cc/")!) == .everything,
          "got \(Categoriser.category(for: URL(string: "https://x1337x.cc/")!).label)")

    print("Test 4 - grouping")
    let items = [bm("https://yts.mx/"), bm("https://1337x.to/home/"),
                 bm("https://dodi-repacks.site/"), bm("https://annas-archive.pk/"),
                 bm("https://eztvx.to/")]
    let groups = Categoriser.group(items)
    check("fixed category order",
          groups.map(\.category) == [.everything, .moviesAndTV, .games, .books],
          "got \(groups.map { $0.category.label })")
    check("empty categories dropped", !groups.contains { $0.items.isEmpty })
    check("every bookmark kept", groups.reduce(0) { $0 + $1.items.count } == items.count)
    check("order inside a group is preserved, so a pinned chip still leads",
          groups.first { $0.category == .moviesAndTV }?.items.map(\.url.host) == ["yts.mx", "eztvx.to"],
          "got \(groups.first { $0.category == .moviesAndTV }?.items.map(\.url.host) ?? [])")
    check("no groups for an empty bar", Categoriser.group([]).isEmpty)

    print("Test 5 - sections that exist so there is somewhere to drop a chip")
    let empty = Categoriser.group([], includingEmpty: true)
    check("four sections even with an empty bar",
          empty.map(\.category) == [.everything, .moviesAndTV, .games, .books],
          "got \(empty.map { $0.category.label })")
    check("nothing is invented to fill them", empty.allSatisfy { $0.items.isEmpty })
    check("Other is not shown when empty", !empty.contains { $0.category == .other })
    check("the old behaviour is unchanged", Categoriser.group([]).isEmpty)
    let withOther = Categoriser.group([bm("https://something-new.example/")], includingEmpty: true)
    check("Other appears once something is unclassified",
          withOther.contains { $0.category == .other },
          "got \(withOther.map { $0.category.label })")

    print("Test 6 - dragging a chip to another section sticks")
    let yts = URL(string: "https://yts.mx/")!
    check("starts where the table says", Categoriser.category(for: yts) == .moviesAndTV)
    CategoryStore.shared.set(.games, for: yts)
    check("override applied", Categoriser.category(for: yts) == .games,
          "got \(Categoriser.category(for: yts).label)")
    check("override is reported as such", CategoryStore.shared.isOverridden(yts))
    check("the chip actually moves section",
          Categoriser.group([bm("https://yts.mx/")], includingEmpty: true)
              .first { $0.category == .games }?.items.count == 1)

    print("Test 7 - an override beats the mirror-set inheritance too")
    let mirror = URL(string: "https://x1337x.cc/")!
    check("inherited before the override", Categoriser.category(for: mirror) == .everything)
    CategoryStore.shared.set(.books, for: mirror)
    check("override wins", Categoriser.category(for: mirror) == .books,
          "got \(Categoriser.category(for: mirror).label)")

    print("Test 8 - reset returns it to automatic")
    CategoryStore.shared.reset(yts)
    check("back to the table's answer", Categoriser.category(for: yts) == .moviesAndTV,
          "got \(Categoriser.category(for: yts).label)")
    check("no longer reported as overridden", !CategoryStore.shared.isOverridden(yts))
    CategoryStore.shared.reset(mirror)
    check("mirror back to inherited", Categoriser.category(for: mirror) == .everything)

    print("Test 9 - sections fold away and stay folded")
    UserDefaults.standard.removeObject(forKey: "bookmarks.collapsedSections")
    let store = CategoryStore.shared
    check("nothing starts collapsed", !store.isCollapsed(.games))
    store.toggleCollapsed(.games)
    check("toggle collapses", store.isCollapsed(.games))
    check("only the one section", !store.isCollapsed(.books))
    check("the choice is written down, so it survives a relaunch",
          (UserDefaults.standard.stringArray(forKey: "bookmarks.collapsedSections") ?? []).contains("games"))
    store.toggleCollapsed(.games)
    check("toggle expands again", !store.isCollapsed(.games))
    store.toggleCollapsed(.books)
    store.expand(.books)
    check("expand un-collapses", !store.isCollapsed(.books))
    store.expand(.books)
    check("expanding an open section is harmless", !store.isCollapsed(.books))

    print("Test 10 - the bar shows icons, so every category needs a real one")
    for category in BookmarkCategory.allCases {
        // A misspelled SF Symbol does not fail the build -- it just renders as
        // nothing, leaving a section with no visible header at all.
        check("\(category.label) has a resolvable symbol (\(category.symbol))",
              NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil) != nil)
    }
    check("symbols are distinct",
          Set(BookmarkCategory.allCases.map(\.symbol)).count == BookmarkCategory.allCases.count)
    check("labels survive for tooltips and menus",
          BookmarkCategory.allCases.allSatisfy { !$0.label.isEmpty })

    UserDefaults.standard.removeObject(forKey: "bookmarks.collapsedSections")
    UserDefaults.standard.removeObject(forKey: "bookmarks.categories")
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
