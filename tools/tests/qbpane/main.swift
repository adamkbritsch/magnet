import AppKit
import Foundation
import WebKit

// The qBittorrent pane: where it sits for every window size, and whether its sign-in
// script reads qBittorrent's answers correctly -- run for real, inside a WKWebView,
// against a local stand-in for each way qBittorrent has answered.

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

// MARK: - Where the pane sits

let full = PaneSplit.frames(for: CGSize(width: 1728, height: 1021), shown: true)
check("a full-width window is split side by side", full.axis == .horizontal)
check("qBittorrent takes the left half", full.pane == CGRect(x: 0, y: 0, width: 864, height: 1021), "\(full.pane)")
check("Magnet takes the right half", full.magnet == CGRect(x: 864, y: 0, width: 864, height: 1021), "\(full.magnet)")

let odd = PaneSplit.frames(for: CGSize(width: 1441, height: 900), shown: true)
check("an odd width leaves no gap and no overlap",
      odd.pane.maxX == odd.magnet.minX && odd.magnet.maxX == 1441, "\(odd)")

let edge = PaneSplit.frames(for: CGSize(width: PaneSplit.sideBySideMinWidth, height: 800), shown: true)
check("at the threshold both halves are usable", edge.axis == .horizontal && edge.pane.width >= 620)
let below = PaneSplit.frames(for: CGSize(width: PaneSplit.sideBySideMinWidth - 1, height: 800), shown: true)
check("just below it, the pane moves to the top", below.axis == .vertical)

let narrow = PaneSplit.frames(for: CGSize(width: 900, height: 1000), shown: true)
check("a narrow window stacks qBittorrent above Magnet",
      narrow.pane == CGRect(x: 0, y: 0, width: 900, height: 500)
        && narrow.magnet == CGRect(x: 0, y: 500, width: 900, height: 500), "\(narrow)")

let short = PaneSplit.frames(for: CGSize(width: 900, height: 560), shown: true)
check("a short narrow window keeps both minimums",
      short.pane.height >= PaneSplit.minPaneHeight && short.magnet.height >= PaneSplit.minMagnetHeight,
      "\(short)")
let tiny = PaneSplit.frames(for: CGSize(width: 900, height: 300), shown: true)
check("a window too short for both never goes negative",
      tiny.pane.height > 0 && tiny.magnet.height > 0 && tiny.pane.height + tiny.magnet.height == 300, "\(tiny)")

let hiddenWide = PaneSplit.frames(for: CGSize(width: 1728, height: 1021), shown: false)
check("hidden in a wide window, Magnet has all of it",
      hiddenWide.magnet == CGRect(x: 0, y: 0, width: 1728, height: 1021))
check("hidden in a wide window, the pane waits off the left edge",
      hiddenWide.pane.maxX <= 0 && hiddenWide.pane.width == 864, "\(hiddenWide.pane)")
let hiddenNarrow = PaneSplit.frames(for: CGSize(width: 900, height: 1000), shown: false)
check("hidden in a narrow window, it waits off the top edge",
      hiddenNarrow.pane.maxY <= 0 && hiddenNarrow.magnet.height == 1000, "\(hiddenNarrow.pane)")

for width in stride(from: CGFloat(900), through: 2600, by: 37) {
    for height in [560, 700, 1021, 1440] as [CGFloat] {
        let f = PaneSplit.frames(for: CGSize(width: width, height: height), shown: true)
        let union = f.pane.union(f.magnet)
        if union != CGRect(x: 0, y: 0, width: width, height: height) || f.pane.intersects(f.magnet) {
            check("\(width)x\(height) tiles the window exactly", false, "\(f)")
        }
    }
}
check("every size from 900 to 2600 wide tiles the window exactly", true)

// MARK: - The divider

let wideSize = CGSize(width: 1728, height: 1021)
let third = PaneSplit.frames(for: wideSize, shown: true, fraction: 0.3)
check("a dragged divider moves the split", third.pane.width == 518 && third.magnet.minX == 518, "\(third)")
check("the grab area straddles the line",
      third.handle.midX == 518 && third.handle.width == PaneSplit.handleThickness, "\(third.handle)")
check("qBittorrent cannot be dragged below its minimum",
      PaneSplit.frames(for: wideSize, shown: true, fraction: 0.05).pane.width == PaneSplit.minPaneWidth)
check("Magnet cannot be dragged below its minimum",
      PaneSplit.frames(for: wideSize, shown: true, fraction: 0.95).magnet.width == PaneSplit.minMagnetWidth)
check("a drag to x=600 stores qBittorrent's share",
      abs(PaneSplit.fraction(forDragTo: 600, in: wideSize) - 600.0 / 1728) < 0.0001)
check("a drag past the edge stores only what the divider can reach",
      PaneSplit.fraction(forDragTo: 5, in: wideSize) * 1728 == PaneSplit.minPaneWidth
        && PaneSplit.fraction(forDragTo: 1720, in: wideSize) * 1728 == 1728 - PaneSplit.minMagnetWidth)
let grown = PaneSplit.frames(for: CGSize(width: 2560, height: 1400), shown: true, fraction: 0.3)
check("the share holds as the window grows", grown.pane.width == 768, "\(grown.pane)")
let tallSize = CGSize(width: 1000, height: 1000)
check("stacked, a drag sets the height share",
      PaneSplit.frames(for: tallSize, shown: true,
                       fraction: PaneSplit.fraction(forDragTo: 400, in: tallSize)).pane.height == 400)
check("stacked, the handle lies across the full width",
      PaneSplit.frames(for: tallSize, shown: true).handle.width == 1000)

// Remembered across launches: what is stored is what a new launch reads back.
MainActor.assumeIsolated {
    AppSettings.shared.qbPaneFractionWide = 0.37
    AppSettings.shared.qbPaneFractionStacked = 0.61
    check("the side-by-side share is saved", UserDefaults.standard.double(forKey: "qb.pane.fraction.wide") == 0.37)
    check("the stacked share is saved separately",
          UserDefaults.standard.double(forKey: "qb.pane.fraction.stacked") == 0.61)
    AppSettings.shared.resetAll()
}

// MARK: - Reading qBittorrent's answers

check("204 sign-in path reads as success", QBPaneAuthScript.interpret("ok") == .success)
check("an existing session sends nothing", QBPaneAuthScript.interpret("already") == .alreadySignedIn)
check("403 stops sign-in for the launch", {
    if case .blocked = QBPaneAuthScript.interpret("denied") { return true }; return false }())
check("another page behind the proxy is skipped, not counted", {
    if case .unavailable = QBPaneAuthScript.interpret("path-mismatch") { return true }; return false }())
check("origin with a port", QBPaneController.origin(of: URL(string: "http://10.0.0.5:8890/")!) == "http://10.0.0.5:8890")
check("base path always ends in a slash", QBPaneController.basePath(of: URL(string: "http://h:1/qb")!) == "/qb/")

// MARK: - The script itself, in a real page

final class Loader: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done = true }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done = true }
}

func spin(until cond: () -> Bool, seconds: Double = 10) {
    let deadline = Date().addingTimeInterval(seconds)
    while !cond() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

let fake = Process()
fake.executableURL = URL(fileURLWithPath: "/usr/bin/env")
let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_qb.py")
fake.arguments = ["python3", "-I", script.path]
let pipe = Pipe()
fake.standardOutput = pipe
try! fake.run()
let port = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    .trimmingCharacters(in: .whitespacesAndNewlines)

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    let loader = Loader()
    web.navigationDelegate = loader

    func run(_ js: String, mode: String, user: String = "admin", pass: String = "pw") -> String {
        let base = URL(string: "http://127.0.0.1:\(port)/\(mode)/")!
        loader.done = false
        web.load(URLRequest(url: base))
        spin(until: { loader.done })
        var out: String?
        var args: [String: Any] = ["expected": QBPaneController.origin(of: base),
                                   "basePath": QBPaneController.basePath(of: base)]
        if js == QBPaneAuthScript.login { args["u"] = user; args["p"] = pass }
        web.callAsyncJavaScript(js, arguments: args, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let v): out = (v as? String) ?? "non-string"
            case .failure(let e): out = "error: \(e.localizedDescription)"
            }
        }
        spin(until: { out != nil })
        return out ?? "timeout"
    }

    check("5.2: not signed in yet", run(QBPaneAuthScript.probe, mode: "m52") == "signed-out")
    check("5.2: wrong password is a rejection", run(QBPaneAuthScript.login, mode: "m52", pass: "nope") == "rejected")
    let r52 = run(QBPaneAuthScript.login, mode: "m52")
    check("5.2: 204 with an empty body signs in", r52 == "ok", r52)
    check("5.2: the session is there afterwards", run(QBPaneAuthScript.probe, mode: "m52") == "already")
    let r51 = run(QBPaneAuthScript.login, mode: "m51")
    check("5.1: 200 \"Ok.\" signs in", r51 == "ok", r51)
    let liar = run(QBPaneAuthScript.login, mode: "liar")
    check("a 204 that set no session is not believed", liar == "rejected", liar)
    let ban = run(QBPaneAuthScript.login, mode: "ban")
    check("403 reads as a ban", ban == "denied", ban)
    let redir = run(QBPaneAuthScript.login, mode: "redir")
    check("a redirected sign-in is refused, not followed", redir == "blocked:login", redir)

    // Run against a page that is not the configured address: nothing may be sent.
    loader.done = false
    web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/m51/")!))
    spin(until: { loader.done })
    var wrong: String?
    web.callAsyncJavaScript(QBPaneAuthScript.login,
                            arguments: ["expected": "http://127.0.0.1:\(port)", "basePath": "/m52/",
                                        "u": "admin", "p": "pw"],
                            in: nil, in: .defaultClient) { wrong = (try? $0.get()) as? String }
    spin(until: { wrong != nil })
    check("a page outside qBittorrent's path gets no password", wrong == "path-mismatch", wrong ?? "nil")
}

// exit() runs no defers, so the stand-in is stopped here or it outlives the suite.
fake.terminate()
fake.waitUntilExit()
print(failures == 0 ? "\nqbpane: all passed" : "\nqbpane: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
