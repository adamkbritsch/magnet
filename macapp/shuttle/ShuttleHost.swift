import AppKit
import SwiftUI

// How Shuttle lives inside Magnet.
//
// Shuttle was its own app: a FileZilla-style front end for the relay on the NAS that
// moves files between the seedbox, the NAS and this Mac. It is now the view that
// covers Magnet's right-hand pane when switched on, with qBittorrent still beside it.
// The relay itself is unchanged and still lives in the shuttle repository; Visionary
// talks to it too, which is why the token and relay.json stay where Shuttle put them
// (~/Library/Application Support/Shuttle/).

/// Everything Shuttle keeps, created ONCE for the life of the app.
///
/// Not the view's own @StateObjects any more: inside Magnet the view is hidden and
/// shown many times, and a store rebuilt on a re-show would forget the transfer
/// history, re-probe the relay and reload both panes. A transfer to this Mac would
/// keep running with no UI attached to it. Owned here, they outlive any of that.
@MainActor
final class ShuttleStores: ObservableObject {
    let store: RelayStore
    let seedbox: BrowseStore
    let dest: BrowseStore
    let sourceTree: TreeStore
    let destTree: TreeStore
    let search: SearchStore
    let sourceSearch: SearchStore
    let favorites: FavoritesStore
    let sourceFavorites: FavoritesStore
    let local: LocalTransfers
    let splits: SplitTreeHandle

    /// The app's one instance, for the quit guard in AppDelegate, which has no view
    /// tree to reach it through.
    private(set) static weak var current: ShuttleStores?

    init() {
        // Before anything reads its settings: the stores below read them in init.
        ShuttleMigration.runOnce()
        TokenStore.seedFromEnvironmentIfEmpty()
        TokenStore.prime()

        let s = RelayStore()
        store = s
        seedbox = BrowseStore(backend: s.seedboxBackend, store: s)
        dest = BrowseStore(backend: s.nasBackend, store: s)
        sourceTree = TreeStore(backend: s.seedboxBackend)
        destTree = TreeStore(backend: s.nasBackend)
        search = SearchStore(backend: s.nasBackend)
        sourceSearch = SearchStore(backend: s.seedboxBackend)
        favorites = FavoritesStore(backend: s.nasBackend)
        sourceFavorites = FavoritesStore(backend: s.seedboxBackend)
        local = LocalTransfers(api: s.api)
        splits = SplitTreeHandle()
        Self.current = self
    }
}

/// Whether Shuttle is on screen. Read by the parts of Shuttle that would otherwise
/// act while hidden behind the browser: its window-wide Esc shortcuts and the
/// reload it does when the app comes back to the front.
@MainActor
final class ShuttlePresence: ObservableObject {
    static let shared = ShuttlePresence()
    @Published var visible = false
}

/// Whether a Shuttle keyboard command may act right now.
///
/// Shuttle's commands are main-menu key equivalents, and a key equivalent is offered
/// to the menu before the focused view sees the key -- so as a separate app, ⌘⌫ in a
/// text field cancelled a transfer and ⌘↩ queued one. In one window with a browser and
/// qBittorrent that is worse, so every command needs Shuttle on screen, no sheet up,
/// and the keyboard not in qBittorrent's pane. `editingKey` is for keys a text field
/// uses itself (⌘⌫ deletes to the start of the line, ⌘↑ goes to the top, ⌘↩ submits):
/// those also stand aside whenever a text field has the keyboard.
@MainActor
func shuttleKeysAllowed(editingKey: Bool) -> Bool {
    guard ShuttlePresence.shared.visible,
          let window = NSApp.mainWindow ?? NSApp.keyWindow,
          window.attachedSheet == nil else { return false }
    let responder = window.firstResponder
    var view = responder as? NSView
    while let current = view {
        if current is QBClickThroughWebView { return false }
        view = current.superview
    }
    if editingKey, responder is NSText { return false }
    return true
}

/// Shuttle's settings and layout, copied once from the standalone app's own defaults
/// into Magnet's, under a `shuttle.` prefix so they can never collide with Magnet's.
///
/// Copied, not moved: the standalone app is left exactly as it was. A key already set
/// here is never overwritten, so running this again changes nothing.
enum ShuttleMigration {
    static let doneKey = "shuttle.migrated"
    /// The standalone app's bundle id, which is its defaults domain. Set at build time
    /// (MAGNET_SHUTTLE_BUNDLE_ID) rather than written here, like Magnet's own; unset,
    /// there is nothing to copy from.
    static var sourceDomain: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MagnetShuttleBundleID") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }
    static let keys = [
        "relay.base",
        "browse.path.source", "browse.path.dest", "browse.path.mac",
        "favorites.seedbox", "favorites.nas", "favorites.mac",
        "table.columns.source", "table.columns.dest",
        "SplitLayout.main.rows", "SplitLayout.main.browse",
        "SplitLayout.source.split", "SplitLayout.dest.split",
    ]

    @discardableResult
    static func runOnce(into target: UserDefaults = .standard,
                        from source: UserDefaults? = sourceDomain.flatMap { UserDefaults(suiteName: $0) }) -> Int {
        // No source configured is not "done": a later build that knows where Shuttle
        // kept its settings must still be able to copy them.
        guard !target.bool(forKey: doneKey), let source else { return 0 }
        var copied = 0
        for key in keys {
            let destination = "shuttle." + key
            guard target.object(forKey: destination) == nil,
                  let value = source.object(forKey: key) else { continue }
            target.set(value, forKey: destination)
            copied += 1
        }
        target.set(true, forKey: doneKey)
        return copied
    }
}

/// The switch that puts Shuttle over the right-hand pane and takes it away again.
/// Drawn the same in Magnet's bar and in Shuttle's, at the same place, so turning it
/// off is a click on the spot that turned it on.
struct ShuttlePill: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Files")
                    .font(.system(size: 12, weight: isOn ? .semibold : .medium))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
        }
        .buttonStyle(QBTabButtonStyle(selected: isOn, resting: Theme.pillFill))
        .help((isOn ? "Hide" : "Show") + " Files (\u{2318}3)")
        .accessibilityLabel(isOn ? "Hide Files" : "Show Files")
    }
}
