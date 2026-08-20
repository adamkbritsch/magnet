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
        // Nothing is ever added to the toolbar. The content is laid out below the
        // titlebar via the normal safe area, so the taller titlebar simply moves it
        // down 8pt -- no view here measures or assumes a titlebar height.
        let toolbar = NSToolbar(identifier: "MagnetChrome")
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.contentView = NSHostingView(rootView: RootView())
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") == nil {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
}
