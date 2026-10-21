import AppKit
import SwiftUI

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private static let frameAutosaveName = "X1337MainWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Provisioned via the environment on first launch so neither password is
        // ever written into the binary or a config file.
        //
        // Nothing here may READ the Keychain. Every read is an ACL check, and an ACL
        // check the user has not permanently approved is a password box -- so priming
        // two stores at launch meant two password boxes on every single launch, before
        // the user had asked for anything. Both are now read lazily, at the point the
        // credential is actually needed: the proxy one only on the Via NAS route, the
        // qBittorrent one only when a magnet is really being sent.
        ProxyCredentialStore.seedFromEnvironmentIfEmpty()
        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.defaultWindow),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Magnet"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = Theme.minWindow
        // Kept, so the Dock icon can bring it back (applicationShouldHandleReopen).
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // An empty unified toolbar exists purely for its geometry, and it is the only
        // way to match the sibling apps' window corners.
        //
        // On macOS 26 the window corner radius TRACKS THE TITLEBAR HEIGHT -- measured
        // on this machine at linked SDK 26.5: 32pt titlebar -> 17.5pt corner, 40pt ->
        // 23pt, 66pt -> 31.5pt. (At SDK 15.5 it is a flat 12.5pt whatever you do.)
        // SeedLocal runs a .unifiedCompact toolbar, so without one here this window's
        // corners were visibly squarer than its siblings'. There is no public API to
        // set a corner radius directly; the titlebar is the only lever.
        //
        // Nothing is ever added to the toolbar.
        let toolbar = NSToolbar(identifier: "MagnetChrome")
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        // Where AppKit actually put the window buttons, so the bars in the titlebar row
        // centre their controls on them. MUST run after the toolbar is attached: the
        // toolbar is what makes the titlebar taller. NSView is bottom-left origin, hence
        // height - midY for a distance from the top.
        window.layoutIfNeeded()
        if let close = window.standardWindowButton(.closeButton), let frameView = close.superview {
            let fromTop = frameView.bounds.height - close.frame.midY
            if fromTop > 4, fromTop < 60 { Theme.trafficLightCenterY = fromTop }
        }
        let host = NSHostingView(rootView: RootView())
        // The top bars ARE the titlebar. Left to its default, the hosting view applies
        // the hidden titlebar's safe area and pushes everything down, which left an
        // empty strip across the top with the bar below-right of the window buttons.
        host.safeAreaRegions = []
        // The window's size is the user's business, not the content's: by default the
        // hosting view publishes the content's ideal size as the window's limits.
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") == nil {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Transfers to and from this Mac run inside this process and die with it, unlike
    /// the relay's, which carry on on the NAS. Shuttle was rarely quit; Magnet is quit
    /// far more often, so it asks first rather than dropping a half-copied file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitConfirmed || confirmQuitWithTransfers() ? .terminateNow : .terminateCancel
    }

    /// The Dock icon brings the window back if it was ever closed without quitting.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Set once the question has been answered "Quit Anyway" on the way out, so
    /// closing the window does not ask it twice.
    private var quitConfirmed = false

    /// True when it is fine to stop: nothing is transferring to or from this Mac, or
    /// the user said to stop anyway.
    private func confirmQuitWithTransfers() -> Bool {
        let running = MainActor.assumeIsolated { ShuttleStores.current?.local.active.count ?? 0 }
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = running == 1
            ? "A transfer to or from this Mac is still running"
            : "\(running) transfers to or from this Mac are still running"
        alert.informativeText = "They stop if Magnet quits, and the files they were copying "
            + "are left incomplete. Transfers on the NAS are not affected."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        let stop = alert.runModal() == .alertSecondButtonReturn
        if stop { quitConfirmed = true }
        return stop
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Magnet",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Magnet",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Magnet",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Without an Edit menu, Cmd-V does nothing in the web view — which would
        // make the search box unusable for pasted titles.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Manual", action: #selector(showManual), keyEquivalent: "1").target = self
        viewMenu.addItem(withTitle: "Automatic", action: #selector(showAutomatic), keyEquivalent: "2").target = self
        viewMenu.addItem(.separator())
        // Control-Command-S is the standard Show/Hide Sidebar key.
        let pane = viewMenu.addItem(withTitle: "Show qBittorrent", action: #selector(toggleQBittorrent),
                                    keyEquivalent: "s")
        pane.keyEquivalentModifierMask = [.command, .control]
        pane.target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "H").target = self
        viewMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[").target = self
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Check Routes Again",
                         action: #selector(recheck), keyEquivalent: "").target = self
        viewMenu.addItem(.separator())
        let fs = viewMenu.addItem(withTitle: "Enter Full Screen",
                                  action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Files: what was Shuttle. Its commands keep Shuttle's keys, but every one of
        // them stands down unless Files is on screen and the keyboard is not in
        // qBittorrent (see validateMenuItem) -- as menu key equivalents they reach the
        // menu before the focused view, so ungated, ⌘⌫ typed into a web page's text
        // field would cancel a transfer.
        let filesItem = NSMenuItem()
        let filesMenu = NSMenu(title: "Files")
        filesMenu.addItem(withTitle: "Show Files", action: #selector(toggleFiles), keyEquivalent: "3").target = self
        filesMenu.addItem(.separator())
        let send = filesMenu.addItem(withTitle: "Send Selection", action: #selector(filesSend), keyEquivalent: "\r")
        send.keyEquivalentModifierMask = [.command]
        send.target = self
        let up = filesMenu.addItem(withTitle: "Enclosing Folder", action: #selector(filesUp),
                                   keyEquivalent: String(format: "%C", 0xF700))
        up.keyEquivalentModifierMask = [.command]
        up.target = self
        let stop = filesMenu.addItem(withTitle: "Stop Transfer", action: #selector(filesStop),
                                     keyEquivalent: String(UnicodeScalar(UInt8(NSDeleteCharacter))))
        stop.keyEquivalentModifierMask = [.command]
        stop.target = self
        filesMenu.addItem(.separator())
        filesMenu.addItem(withTitle: "Find\u{2026}", action: #selector(filesFind), keyEquivalent: "f").target = self
        filesMenu.addItem(withTitle: "Favorites", action: #selector(filesFavorites), keyEquivalent: "F").target = self
        filesMenu.addItem(withTitle: "Add This Folder to Favorites", action: #selector(filesAddFavorite),
                          keyEquivalent: "d").target = self
        filesMenu.addItem(.separator())
        filesMenu.addItem(withTitle: "Source Directory Tree", action: #selector(filesSourceTree),
                          keyEquivalent: "").target = self
        filesMenu.addItem(withTitle: "Destination Directory Tree", action: #selector(filesDestTree),
                          keyEquivalent: "").target = self
        filesMenu.addItem(withTitle: "Transfer Queue", action: #selector(filesQueue), keyEquivalent: "").target = self
        filesMenu.addItem(withTitle: "Reset Layout", action: #selector(filesResetLayout), keyEquivalent: "").target = self
        filesItem.submenu = filesMenu
        mainMenu.addItem(filesItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openSettings() { NotificationCenter.default.post(name: .qbSettings, object: nil) }
    @objc private func goHome() { NotificationCenter.default.post(name: .qbHome, object: nil) }
    @objc private func goBack() { NotificationCenter.default.post(name: .qbBack, object: nil) }
    @objc private func reload() { NotificationCenter.default.post(name: .qbReload, object: nil) }
    @objc private func recheck() { NotificationCenter.default.post(name: .qbRecheck, object: nil) }
    @objc private func showManual() { NotificationCenter.default.post(name: .qbModeManual, object: nil) }
    @objc private func showAutomatic() { NotificationCenter.default.post(name: .qbModeAutomatic, object: nil) }
    @objc private func toggleQBittorrent() { NotificationCenter.default.post(name: .qbTogglePane, object: nil) }

    @objc private func toggleFiles() { post(.shuttleToggle) }
    @objc private func filesSend() { post(.shuttleSend) }
    @objc private func filesUp() { post(.shuttleUp) }
    @objc private func filesStop() { post(.shuttleCancel) }
    @objc private func filesFind() { post(.shuttleFind) }
    @objc private func filesFavorites() { post(.shuttleFavorites) }
    @objc private func filesAddFavorite() { post(.shuttleAddFavorite) }
    @objc private func filesSourceTree() { post(.shuttleToggleSourceTree) }
    @objc private func filesDestTree() { post(.shuttleToggleDestTree) }
    @objc private func filesQueue() { post(.shuttleToggleQueue) }
    @objc private func filesResetLayout() { post(.shuttleResetLayout) }
    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleQBittorrent) {
            let settings = AppSettings.shared
            item.title = settings.qbPaneVisible ? "Hide qBittorrent" : "Show qBittorrent"
            // Nothing to show until qBittorrent's address is set.
            return settings.qbPaneAvailable
        }
        let flags = MenuState.shared.flags
        switch item.action {
        case #selector(toggleFiles):
            item.title = AppSettings.shared.shuttleShown ? "Hide Files" : "Show Files"
            // Never under a sheet: see RootView.sheetAttached.
            return (NSApp.mainWindow ?? NSApp.keyWindow)?.attachedSheet == nil
        case #selector(showManual), #selector(showAutomatic), #selector(goHome):
            return (NSApp.mainWindow ?? NSApp.keyWindow)?.attachedSheet == nil
        // Keys a text field uses itself stand aside for one, even inside Files.
        case #selector(filesSend): return shuttleKeysAllowed(editingKey: true) && flags.canSend
        case #selector(filesUp): return shuttleKeysAllowed(editingKey: true) && flags.canGoUp
        case #selector(filesStop): return shuttleKeysAllowed(editingKey: true) && flags.hasSelectedTransfer
        case #selector(filesFind), #selector(filesFavorites), #selector(filesAddFavorite):
            return shuttleKeysAllowed(editingKey: false) && flags.isLive
        case #selector(filesSourceTree), #selector(filesDestTree), #selector(filesQueue),
             #selector(filesResetLayout):
            return AppSettings.shared.shuttleShown
        default:
            return true
        }
    }
}

/// Closing the window quits the app, so it asks the quit question BEFORE the window
/// goes: answered "Keep Running" afterwards, the app would be left running with
/// nothing on screen.
extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        quitConfirmed || confirmQuitWithTransfers()
    }
}
