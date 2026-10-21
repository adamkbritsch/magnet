import AppKit
import SwiftUI

// Files (what was Shuttle) inside Magnet, and the window's qBittorrent look: the
// one-time copy of Shuttle's settings, and the palette read from qBittorrent's CSS.

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

// MARK: - Shuttle's settings, copied once

func scratch(_ tag: String) -> (UserDefaults, String) {
    let name = "magnet-tests-\(tag)-\(ProcessInfo.processInfo.processIdentifier)"
    return (UserDefaults(suiteName: name)!, name)
}

let (old, oldName) = scratch("shuttle")
let (new, newName) = scratch("magnet")
old.set("http://relay.example:8789", forKey: "relay.base")
old.set("/queue/Media/TV", forKey: "browse.path.dest")
old.set(Data([1, 2, 3]), forKey: "SplitLayout.main.rows")
old.set("left alone", forKey: "NSWindow Frame ShuttleMainWindow")
new.set("/already/here", forKey: "shuttle.browse.path.dest")

let copied = ShuttleMigration.runOnce(into: new, from: old)
check("copies what Shuttle had", copied == 2, "copied \(copied)")
check("under a shuttle. prefix", new.string(forKey: "shuttle.relay.base") == "http://relay.example:8789")
check("binary layouts come across intact", new.data(forKey: "shuttle.SplitLayout.main.rows") == Data([1, 2, 3]))
check("never overwrites a value Magnet already has",
      new.string(forKey: "shuttle.browse.path.dest") == "/already/here")
check("leaves Shuttle's own window frame behind",
      new.object(forKey: "shuttle.NSWindow Frame ShuttleMainWindow") == nil)
check("leaves the standalone app's settings untouched",
      old.string(forKey: "relay.base") == "http://relay.example:8789")
old.set("http://changed.example:8789", forKey: "relay.base")
check("runs once only", ShuttleMigration.runOnce(into: new, from: old) == 0
      && new.string(forKey: "shuttle.relay.base") == "http://relay.example:8789")
let (fresh, freshName) = scratch("fresh")
check("with nowhere to copy from, nothing is copied and nothing is marked done",
      ShuttleMigration.runOnce(into: fresh, from: nil) == 0 && !fresh.bool(forKey: ShuttleMigration.doneKey))
for n in [oldName, newName, freshName] { UserDefaults.standard.removePersistentDomain(forName: n) }

// MARK: - qBittorrent's palette

func rgb(_ c: NSColor) -> [Int] {
    let s = c.usingColorSpace(.sRGB)!
    return [s.redComponent, s.greenComponent, s.blueComponent].map { Int(($0 * 255).rounded()) }
}
check("hsl(210 65% 55%) is the WebUI's light accent, rgb(66,140,215)",
      rgb(Theme.hsl(210, 65, 55)) == [66, 140, 215], "\(rgb(Theme.hsl(210, 65, 55)))")
check("hsl(26 80% 60%) is its orange hover, rgb(235,142,71)",
      rgb(Theme.hsl(26, 80, 60)) == [235, 142, 71], "\(rgb(Theme.hsl(26, 80, 60)))")
check("hsl(0 0% 25%) is its dark chrome, rgb(64,64,64)", rgb(Theme.hsl(0, 0, 25)) == [64, 64, 64])
check("hsl(0 0% 7%) is its dark list background, rgb(18,18,18)", rgb(Theme.hsl(0, 0, 7)) == [18, 18, 18])

func resolved(_ ns: NSColor, _ look: NSAppearance.Name) -> [Int] {
    var out: [Int] = []
    NSAppearance(named: look)!.performAsCurrentDrawingAppearance { out = rgb(ns) }
    return out
}
check("chrome follows the appearance like the WebUI's .dark class",
      resolved(Theme.chromeNS, .aqua) == [240, 240, 240] && resolved(Theme.chromeNS, .darkAqua) == [64, 64, 64],
      "\(resolved(Theme.chromeNS, .aqua)) \(resolved(Theme.chromeNS, .darkAqua))")

// The WebUI's rule: orange under the pointer, blue once chosen, hover winning.
check("hover is orange", QBFill.background(hovering: true, selected: false) == Theme.hover)
check("selected is blue", QBFill.background(hovering: false, selected: true) == Theme.accent)
check("hover wins over selected, as on a selected row", QBFill.background(hovering: true, selected: true) == Theme.hover)
check("text goes white on either", QBFill.foreground(hovering: true, selected: false) == .white
      && QBFill.foreground(hovering: false, selected: true) == .white)
check("a disabled control ignores the pointer",
      QBFill.background(hovering: true, selected: false, enabled: false) == .clear)

print(failures == 0 ? "\nfiles: all passed" : "\nfiles: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
