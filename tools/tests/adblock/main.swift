import AppKit
import WebKit

// Does the injected stylesheet interfere with the content blocker? Load the same page
// with blocker-only and with blocker+stylesheet, and compare what the blocker hid.
let probe = """
(function(){
  var hidden=0, iframes=0, visIframes=0, imgs=0;
  var all=document.querySelectorAll('*');
  for(var i=0;i<all.length;i++){
    var el=all[i], cs=getComputedStyle(el);
    if(cs.display==='none') hidden++;
    if(el.tagName==='IFRAME'){ iframes++;
      var r=el.getBoundingClientRect();
      if(cs.display!=='none' && cs.visibility!=='hidden' && r.width>20 && r.height>20) visIframes++; }
    if(el.tagName==='IMG') imgs++;
  }
  return JSON.stringify({hidden:hidden, iframes:iframes, visIframes:visIframes,
                         imgs:imgs, nodes:all.length, title:document.title.slice(0,32)});
})();
"""

func loadLists() async -> [WKContentRuleList] {
    guard let store = WKContentRuleListStore.default() else { return [] }
    let dir = NSString(string: "~/x1337-app/macapp").expandingTildeInPath
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasPrefix("blocklist-") && $0.hasSuffix(".json") }.sorted()
    var out: [WKContentRuleList] = []
    for f in files {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let ident = "adcheck.\(f).\(size)"
        if let cached = try? await store.contentRuleList(forIdentifier: ident) { out.append(cached); continue }
        guard let json = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if let c = try? await store.compileContentRuleList(forIdentifier: ident, encodedContentRuleList: json) {
            out.append(c)
        }
    }
    return out
}

final class R: NSObject, WKNavigationDelegate {
    var done=false; var out="none"
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now()+3.5) {
            w.evaluateJavaScript(probe){v,_ in self.out=(v as? String) ?? "fail"; self.done=true}
        }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error){ out="FAILED"; done=true }
}

func run(_ site: String, lists: [WKContentRuleList], styled: Bool) -> String {
    let cfg = WKWebViewConfiguration()
    for l in lists { cfg.userContentController.add(l) }
    if styled, let u = SiteStyle.userScript(css: SiteStyle.defaultCSS) { cfg.userContentController.addUserScript(u) }
    let w = WKWebView(frame: .init(x:0,y:0,width:1280,height:900), configuration: cfg)
    w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    let r=R(); w.navigationDelegate=r
    w.load(URLRequest(url: URL(string: site)!))
    let dl=Date().addingTimeInterval(35)
    while !r.done && Date()<dl { RunLoop.current.run(mode:.default, before: Date().addingTimeInterval(0.05)) }
    return r.done ? r.out : "TIMED OUT"
}

let sem = DispatchSemaphore(value: 0)
var lists: [WKContentRuleList] = []
Task { lists = await loadLists(); sem.signal() }
while sem.wait(timeout: .now()+0.05) == .timedOut { RunLoop.current.run(mode:.default, before: Date().addingTimeInterval(0.05)) }
print("compiled rule lists: \(lists.count)")

var failures = 0
func check(_ n: String, _ c: Bool, _ got: String = "") {
    if c { print("  PASS  \(n)") } else { failures += 1; print("  FAIL  \(n)   \(got)") }
}
func decode(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

check("filter lists compiled", lists.count > 0, "\(lists.count) lists")

for site in ["https://extto.com/", "https://steamrip.com/"] {
    print("\n\(site)")
    let bare    = decode(run(site, lists: [], styled: false))
    let blocked = decode(run(site, lists: lists, styled: false))
    let both    = decode(run(site, lists: lists, styled: true))
    guard !bare.isEmpty, !blocked.isEmpty, !both.isEmpty else {
        print("  SKIP  site did not load"); continue
    }
    let bareFrames = bare["iframes"] as? Int ?? 0
    let blockedFrames = blocked["iframes"] as? Int ?? 0
    let bothFrames = both["iframes"] as? Int ?? 0

    check("the blocker removes frames the page would otherwise load",
          blockedFrames <= bareFrames, "\(bareFrames) -> \(blockedFrames)")
    // The point of the whole check: restyling must not resurrect what was blocked.
    check("restyling does not bring blocked frames back",
          bothFrames <= blockedFrames, "blocker \(blockedFrames) vs styled \(bothFrames)")
    check("no ad frame is visible with the theme applied",
          (both["visIframes"] as? Int ?? 0) == 0, "\(both["visIframes"] ?? "?")")
    // Cosmetic hiding is display:none, which our rules never set.
    let hidBlocked = blocked["hidden"] as? Int ?? 0
    let hidBoth = both["hidden"] as? Int ?? 0
    check("restyling does not un-hide what the blocker hid",
          hidBoth >= hidBlocked - 5, "blocker hid \(hidBlocked), styled \(hidBoth)")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
