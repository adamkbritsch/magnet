import AppKit
import SwiftUI

/// Shuttle's palette and pane metrics, inside Magnet.
///
/// Shuttle was its own app; it is now the view that covers Magnet's right-hand pane.
/// The chrome it shares with the rest of the window -- bar height, hairline, pill
/// fills, the window-button gutter -- comes from Magnet's `Theme`, so the two bars
/// read as one window. What is here is Shuttle's own: the FileZilla-sampled colours,
/// the split-tree seeds and minimums, and its holding priorities.
enum ShuttleTheme {
    static var hairline: Color { Theme.hairline }
    static var pillFill: Color { Theme.pillFill }

    // MARK: - Colours
    //
    // The window's look, which is qBittorrent's (see Theme): lists on its surface,
    // everything around them on its chrome, its blue for what is chosen.
    static var listFill: Color { Theme.surface }
    static var cardFill: Color { Theme.chrome }
    static var headerFill: Color { Theme.chrome }
    static var folderGold: Color { Theme.accent }
    static var fileGrey: Color { Theme.textDisabled }
    static var accent: Color { Theme.accent }
    static var accentSoft: Color { Theme.accent.opacity(0.25) }
    static var accentIndigo: Color { Theme.blue }

    // Divider geometry. These are SEEDS for a first launch, not frames — every
    // divider's real position is restored from UserDefaults after that.
    static let queueSeed: CGFloat = 224
    static let queueMin: CGFloat = 90
    static let treeSeed: CGFloat = 150
    static let treeMin: CGFloat = 60
    static let listMin: CGFloat = 120
    static let browseMin: CGFloat = 220
    static let paneMinWidth: CGFloat = 330
    static let statusLineHeight: CGFloat = 20
    /// A 1pt hairline is impossible to grab, so the divider claims 3pt either side.
    static let dividerHitSlop: CGFloat = 3

    /// Holding priority decides which pane absorbs a window resize: the LOWER
    /// priority grows. Measured, and the opposite of what reads naturally.
    ///   equal (250/250) -> gravity 0.5, panes share growth
    ///   tree 251 / list 250 -> the list absorbs, the tree holds its height
    ///   browse 250 / queue 260 -> browse absorbs, the queue holds 224
    enum Hold {
        static let absorbs = NSLayoutConstraint.Priority(250)
        static let holds = NSLayoutConstraint.Priority(251)
        static let holdsFirmly = NSLayoutConstraint.Priority(260)
    }

    static let splitKeys = ["main.rows", "main.browse", "source.split", "dest.split"]
}

/// Status colors, semantic rather than literal so both appearances read correctly.
enum ShuttleTint {
    case good, busy, warn, bad, idle

    var color: Color {
        switch self {
        case .good: return Theme.green
        case .busy: return ShuttleTheme.accent
        case .warn: return Theme.orange
        case .bad:  return Theme.red
        case .idle: return Color.secondary
        }
    }
}

/// 1024-based sizes, matching render.py's `human()` on the NAS, so a number in this
/// app and the same number in an FTP listing read identically.
func humanBytes(_ n: Int64) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(n)
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v))B" : String(format: "%.1f%@", v, units[i])
}

func humanETA(_ seconds: Int) -> String {
    if seconds <= 0 { return "--" }
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60, s = seconds % 60
    if m < 60 { return s > 0 ? "\(m)m\(s)s" : "\(m)m" }
    let h = m / 60
    return "\(h)h\(m % 60)m"
}

/// What the AppKit menu bar needs to know about the SwiftUI tree in order to grey
/// items out honestly.
///
/// Deliberately a small snapshot rather than a reference to the stores: the menu and
/// the view tree stay decoupled — commands travel one way as notifications (below),
/// and this carries the answers back the other way without either side holding the
/// other. Every custom item used to be permanently black, so ⌘⌫ with nothing
/// transferring and ⌘↩ with nothing selected both looked live and did nothing.
struct MenuFlags: Equatable {
    var canSend = false
    var canGoUp = false
    var hasSelectedTransfer = false
    var isLive = false
}

@MainActor
final class MenuState {
    static let shared = MenuState()
    var flags = MenuFlags()
}

// Menu commands are posted as notifications so the AppKit menu bar and the SwiftUI
// tree stay decoupled — neither has to hold a reference to the other.
extension Notification.Name {
    static let shuttleSettings = Notification.Name("shuttle.settings")
    static let shuttleRefresh = Notification.Name("shuttle.refresh")
    static let shuttleSend = Notification.Name("shuttle.send")
    static let shuttleUp = Notification.Name("shuttle.up")
    static let shuttleCancel = Notification.Name("shuttle.cancel")
    // View menu, mirroring FileZilla's pane toggles.
    static let shuttleToggleSourceTree = Notification.Name("shuttle.toggleSourceTree")
    static let shuttleToggleDestTree = Notification.Name("shuttle.toggleDestTree")
    static let shuttleToggleQueue = Notification.Name("shuttle.toggleQueue")
    static let shuttleResetLayout = Notification.Name("shuttle.resetLayout")
    static let shuttleFind = Notification.Name("shuttle.find")
    static let shuttleFavorites = Notification.Name("shuttle.favorites")
    static let shuttleAddFavorite = Notification.Name("shuttle.addFavorite")
    /// Show or hide Shuttle over Magnet's right-hand pane.
    static let shuttleToggle = Notification.Name("shuttle.toggle")
    /// Bring Files on screen because one of its sheets is opening.
    static let shuttleReveal = Notification.Name("shuttle.reveal")
}
