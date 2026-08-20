import Foundation

/// What a site is FOR, so the bar reads as sections rather than one long run of
/// chips. `everything` and `other` are not the same thing: the first is a
/// deliberate call that a site covers several types, the second is a site nobody
/// has classified yet.
enum BookmarkCategory: String, CaseIterable, Identifiable {
    case everything
    case moviesAndTV
    case games
    case books
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everything:  return "Everything"
        case .moviesAndTV: return "Movies & TV"
        case .games:       return "Games"
        case .books:       return "Books"
        case .other:       return "Other"
        }
    }

    /// The bar shows these instead of the words. SF Symbols rather than any bitmap
    /// or emoji: they are vector, they inherit weight and colour from the label they
    /// replace, and they match the chevrons and shield already in the chrome.
    /// `label` still carries the name for tooltips and menus.
    var symbol: String {
        switch self {
        case .everything:  return "square.grid.2x2"
        case .moviesAndTV: return "film"
        case .games:       return "gamecontroller"
        case .books:       return "books.vertical"
        case .other:       return "ellipsis.circle"
        }
    }
}

struct BookmarkGroup: Identifiable {
    let category: BookmarkCategory
    let items: [Bookmark]
    var id: String { category.rawValue }
}

/// Sorts bookmarks into categories.
///
/// Deliberately a small explicit table rather than derived from FMHY's own section
/// headings. Measured 2026-08-19: FMHY lists most sites in several sections and the
/// FIRST mention is routinely not the site's purpose -- RuTracker first appears
/// under "ROM Sites", 1337x under "Movies / Shows", and FMHY itself under
/// "Adblocking". Deriving categories from that produces visibly wrong groups, and
/// there are few enough chips that naming them is both accurate and cheap.
/// User corrections to the built-in table, keyed by registrable domain.
///
/// Observable rather than read straight from UserDefaults so dragging a chip into
/// another section regroups the bar immediately. Still just the
/// `bookmarks.categories` default underneath, so it can also be set by hand.
@MainActor
final class CategoryStore: ObservableObject {
    static let shared = CategoryStore()

    private static let key = "bookmarks.categories"
    private static let collapsedKey = "bookmarks.collapsedSections"

    @Published private(set) var overrides: [String: BookmarkCategory] = [:]
    /// Sections the user has folded away, by raw value.
    @Published private(set) var collapsed: Set<String> = []

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        overrides = raw.compactMapValues(BookmarkCategory.init(rawValue:))
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    func isCollapsed(_ category: BookmarkCategory) -> Bool {
        collapsed.contains(category.rawValue)
    }

    func toggleCollapsed(_ category: BookmarkCategory) {
        if collapsed.contains(category.rawValue) { collapsed.remove(category.rawValue) }
        else { collapsed.insert(category.rawValue) }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    func expand(_ category: BookmarkCategory) {
        guard collapsed.contains(category.rawValue) else { return }
        collapsed.remove(category.rawValue)
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    func set(_ category: BookmarkCategory, for url: URL) {
        guard let host = url.host else { return }
        overrides[registrableDomain(host)] = category
        persist()
    }

    /// Back to whatever the built-in table says.
    func reset(_ url: URL) {
        guard let host = url.host else { return }
        overrides.removeValue(forKey: registrableDomain(host))
        persist()
    }

    func isOverridden(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return overrides[registrableDomain(host)] != nil
    }

    private func persist() {
        UserDefaults.standard.set(overrides.mapValues(\.rawValue), forKey: Self.key)
    }
}

enum Categoriser {

    private static let table: [String: BookmarkCategory] = [
        // Multi-purpose trackers and meta search. Filing these under any single
        // heading would be wrong, so they get their own.
        "1337x.to": .everything,
        "extto.com": .everything,
        "ext.to": .everything,
        "torrentbay.st": .everything,
        "knaben.org": .everything,
        "rutracker.org": .everything,
        "rutracker.net": .everything,
        "limetorrents.fun": .everything,
        "rarbgdump.com": .everything,
        "fmhy.net": .everything,

        "yts.mx": .moviesAndTV,
        "eztvx.to": .moviesAndTV,
        "nyaa.si": .moviesAndTV,
        "nyaa.iss.one": .moviesAndTV,
        "nyaa.iss.ink": .moviesAndTV,

        "dodi-repacks.site": .games,
        "fitgirl-repacks.site": .games,
        "steamrip.com": .games,

        "annas-archive.pk": .books,
        "annas-archive.gd": .books,
        "annas-archive.gl": .books,
        "theaudiobookbay.se": .books,
    ]

    @MainActor
    static func category(for url: URL) -> BookmarkCategory {
        guard let host = url.host else { return .other }
        if let known = lookup(registrableDomain(host)) { return known }

        // A site that changed domain keeps its category: ask the mirror set whether
        // any sibling domain is classified. Anna's Archive rotates domains under
        // takedown orders, so this is the normal case, not an edge case.
        if let set = MirrorDirectory.shared.set(owning: url) {
            for candidate in set.candidates {
                if let host = candidate.host, let known = lookup(registrableDomain(host)) { return known }
            }
        }
        return .other
    }

    @MainActor
    private static func lookup(_ domain: String) -> BookmarkCategory? {
        CategoryStore.shared.overrides[domain] ?? table[domain]
    }

    /// Categories that always get a section in the bar, so there is somewhere to drop
    /// a chip even when nothing is filed under it yet. `other` is not one of them --
    /// it only appears when something is genuinely unclassified, and the way back to
    /// automatic is the chip's own Reset Category command.
    static let alwaysShown: [BookmarkCategory] = [.everything, .moviesAndTV, .games, .books]

    /// Groups in a fixed order. Order inside a group is preserved, so a pinned chip
    /// still leads its own section.
    @MainActor
    static func group(_ bookmarks: [Bookmark], includingEmpty: Bool = false) -> [BookmarkGroup] {
        BookmarkCategory.allCases.compactMap { category in
            let items = bookmarks.filter { self.category(for: $0.url) == category }
            if items.isEmpty, !(includingEmpty && alwaysShown.contains(category)) { return nil }
            return BookmarkGroup(category: category, items: items)
        }
    }
}
