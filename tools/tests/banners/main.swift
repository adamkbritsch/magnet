import AppKit
import WebKit

// The shapes that must be hidden, and the ones that must survive.
let page = """
<html><body style="background:#fff">
  <a id="adlink" href="https://someadvertiser.example/offer">
    <img id="adimg" style="width:728px;height:90px"
         src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="></a>

  <!-- artwork hosted elsewhere, even though the link stays on site -->
  <a id="adlink2" href="/local">
    <img id="adimg2" style="width:970px;height:90px"
         src="https://cdn.someadvertiser.example/banner.gif"></a>

  <!-- a poster: tall, and leaving the site. Must survive. -->
  <a id="poster" href="https://elsewhere.example/movie">
    <img id="posterimg" style="width:300px;height:450px"
         src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="></a>

  <!-- the site's OWN wide announcement. Must survive. -->
  <a id="own" href="/news">
    <img id="ownimg" style="width:900px;height:80px"
         src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="></a>

  <!-- a full-window transparent link: click anywhere, go to an advert -->
  <a id="catcher" href="https://someadvertiser.example/pop"
     style="position:fixed;inset:0;width:1200px;height:800px;z-index:9999"></a>

  <!-- a big link that actually contains a picture. Must survive. -->
  <a id="bigcontent" href="https://elsewhere.example/x"
     style="position:absolute;top:0;left:0;width:1200px;height:800px">
    <img style="width:300px;height:450px"
         src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="></a>

  <!-- a small off-site icon. Must survive. -->
  <a id="icon" href="https://elsewhere.example/x">
    <img id="iconimg" style="width:88px;height:31px"
         src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="></a>
</body></html>
"""

var failures = 0
func check(_ n: String, _ c: Bool, _ got: String = "") {
    if c { print("  PASS  \(n)") } else { failures += 1; print("  FAIL  \(n)   \(got)") }
}

final class R: NSObject, WKNavigationDelegate {
    var done = false; var result: [String: String] = [:]
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let js = """
        (function(){
          function d(id){ var e=document.getElementById(id);
            return e ? getComputedStyle(e).display : 'missing'; }
          return JSON.stringify({ adlink:d('adlink'), adlink2:d('adlink2'),
            poster:d('poster'), own:d('own'), icon:d('icon'),
            catcher:d('catcher'), bigcontent:d('bigcontent') });
        })();
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            w.evaluateJavaScript(js) { v, _ in
                if let s = v as? String, let dt = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: dt) as? [String: String] {
                    self.result = o
                }
                self.done = true
            }
        }
    }
}

let cfg = WKWebViewConfiguration()
cfg.userContentController.addUserScript(BannerBlocker.userScript())
let w = WKWebView(frame: .init(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
let r = R(); w.navigationDelegate = r
w.loadHTMLString(page, baseURL: URL(string: "https://tracker.example/"))
let deadline = Date().addingTimeInterval(20)
while !r.done && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }

print("Self-hosted banners are hidden")
check("a wide banner linking off-site is hidden", r.result["adlink"] == "none", r.result["adlink"] ?? "?")
check("a wide banner whose ARTWORK is off-site is hidden", r.result["adlink2"] == "none", r.result["adlink2"] ?? "?")

print("\nContent with the same destination must survive")
// Requiring BOTH wide-and-short AND off-site is what protects these.
check("a poster leaving the site survives (tall, not a banner)",
      r.result["poster"] != "none", r.result["poster"] ?? "?")
check("the site's OWN wide banner survives (wide, but not off-site)",
      r.result["own"] != "none", r.result["own"] ?? "?")
check("a small off-site badge survives (too small to be a display ad)",
      r.result["icon"] != "none", r.result["icon"] ?? "?")

print("\nFull-window click-catchers are removed")
// A click on one of these is a genuine link activation, so a navigation policy sees
// nothing wrong. Only the shape gives it away.
check("a viewport-sized empty link is hidden", r.result["catcher"] == "none", r.result["catcher"] ?? "?")
check("a big link that holds a picture survives",
      r.result["bigcontent"] != "none", r.result["bigcontent"] ?? "?")

print("\nNavigation is an allow-list, not a block-list")
let here = URL(string: "https://tracker.example/browse")!
let advert = URL(string: "https://someadvertiser.example/offer")!
let knownSites: Set<String> = ["tracker.example", "othertracker.example"]

/// The chain state AT THE MOMENT a navigation is judged: anchored at the page you are
/// on, never at the destination being decided. Aiming it at the destination first was
/// the bug -- `anchor == destination` then always held and every click was allowed.
func onPage(_ d: String) -> RedirectGuard.Chain { .init(appInitiated: false, anchorDomain: d) }
let appChain = RedirectGuard.Chain(appInitiated: true, anchorDomain: "tracker.example")

func decide(_ dest: URL,
            _ kind: RedirectGuard.NavigationKind,
            chain: RedirectGuard.Chain,
            approved: Set<String> = [],
            denied: Set<String> = []) -> RedirectGuard.Decision {
    RedirectGuard.decide(from: here, to: dest, navigationType: kind, chain: chain,
                         known: knownSites, approved: approved, denied: denied)
}

// The case two block-list heuristics failed to catch: the click is same-domain and
// ordinary, and the SERVER redirects out of it.
check("an on-site redirector bouncing the window off-site is blocked",
      decide(advert, .script, chain: onPage("tracker.example")) == .block)
check("a page moving itself somewhere unknown is blocked",
      decide(advert, .script, chain: onPage("tracker.example")) == .block)
check("a page moving itself cannot be confirmed by clicking",
      decide(advert, .script, chain: onPage("tracker.example")) != .confirm)

print("\nWhat must still work")
check("a mirror redirect in an app-initiated chain is allowed",
      decide(URL(string: "https://tracker-canonical.example/")!, .script, chain: appChain) == .allow)
check("moving around the current site is allowed",
      decide(URL(string: "https://tracker.example/page/2")!, .script,
             chain: onPage("tracker.example")) == .allow)
check("a subdomain of the current site is allowed",
      decide(URL(string: "https://cdn.tracker.example/x")!, .script,
             chain: onPage("tracker.example")) == .allow)
check("another site from your own bar is allowed outright",
      decide(URL(string: "https://othertracker.example/")!, .userLink,
             chain: onPage("othertracker.example")) == .allow)
// REGRESSION. This previously asserted `.allow`, by passing a chain already aimed at
// the advertiser -- which is precisely the mistake the code was making, so the suite
// stayed green while the app kept redirecting. A click is judged against where it came
// FROM, not where it is going.
check("a click to an unknown site is judged against the page it came from",
      decide(advert, .userLink, chain: onPage("tracker.example")) == .confirm)
check("once permitted, that destination's own redirects are allowed",
      decide(URL(string: "https://someadvertiser.example/step2")!, .script,
             chain: onPage("someadvertiser.example")) == .allow)
check("a magnet link is left alone", decide(URL(string: "magnet:?xt=urn:btih:a")!, .script,
                                            chain: onPage("tracker.example")) == .allow)

print("\nA deliberate outbound link is possible, just not automatic")
let newSite = URL(string: "https://somewhere-new.example/")!
check("clicking through to an unknown site asks first",
      decide(newSite, .userLink, chain: onPage("tracker.example")) == .confirm)
check("a dialog approval admits the whole domain",
      decide(newSite, .userLink, chain: onPage("tracker.example"),
             approved: ["somewhere-new.example"]) == .allow)
check("approving one domain does not admit a different one",
      decide(advert, .script, chain: onPage("tracker.example"),
             approved: ["somewhere-new.example"]) == .block)

print("\nTHE BYPASS: the page must not be able to approve itself")
// In the wild, the advert fired twice. The first attempt reported as a link
// activation -- a script calling click() on an anchor it just made is one, WebKit
// does not distinguish -- and armed the click-again confirmation. The second
// attempt, pure script to the same URL seconds later, matched it and was allowed.
// The old suite checked that a confirmation did not admit a DIFFERENT URL, and
// never that a script to the SAME one was refused. Approval now exists only as a
// per-domain verdict handed out by a dialog, so at this layer the second attempt
// is judged like the first:
check("a script navigation to a just-confirmed URL is still blocked",
      decide(newSite, .script, chain: onPage("tracker.example")) == .block)
check("and a repeated link activation still only asks",
      decide(newSite, .userLink, chain: onPage("tracker.example")) == .confirm)

print("\nA refusal holds for the session")
check("a denied domain is blocked even from a link activation",
      decide(advert, .userLink, chain: onPage("tracker.example"),
             denied: ["someadvertiser.example"]) == .block)
check("denial is not the toast-and-ask outcome",
      decide(advert, .userLink, chain: onPage("tracker.example"),
             denied: ["someadvertiser.example"]) != .confirm)
check("refusal outranks an aimed chain",
      decide(advert, .script, chain: onPage("someadvertiser.example"),
             denied: ["someadvertiser.example"]) == .block)
check("but a refusal elsewhere changes nothing here",
      decide(newSite, .userLink, chain: onPage("tracker.example"),
             denied: ["someadvertiser.example"]) == .confirm)

print("\nA link activation needs a real click behind it")
// WebKit calls a scripted click() on an anchor a link activation. The in-page
// listener records what REAL pointers land on -- isTrusted cannot be forged -- and a
// claimed activation with no matching click is judged as the script it is.
let now = Date()
func clicks(_ entries: (String, TimeInterval)...) -> [(domain: String, at: Date)] {
    entries.map { ($0.0, now.addingTimeInterval(-$0.1)) }
}
check("a real click on a link to the destination makes it believable",
      RedirectGuard.clickMatches(destination: advert,
                                 clicks: clicks(("someadvertiser.example", 0.3)), now: now))
check("with no clicks at all, it is not",
      !RedirectGuard.clickMatches(destination: advert, clicks: [], now: now))
// The hijack scenario: the user really clicked, but on something else entirely.
check("a real click on a DIFFERENT link does not lend its trust",
      !RedirectGuard.clickMatches(destination: advert,
                                  clicks: clicks(("tracker.example", 0.2)), now: now))
check("a stale click has expired",
      !RedirectGuard.clickMatches(destination: advert,
                                  clicks: clicks(("someadvertiser.example", 3.5)), now: now))
check("matching is by domain, not exact URL, so rewritten hrefs still count",
      RedirectGuard.clickMatches(destination: URL(string: "https://sub.someadvertiser.example/x?y=1")!,
                                 clicks: clicks(("someadvertiser.example", 0.5)), now: now))
check("a click stamped in the future is not evidence",
      !RedirectGuard.clickMatches(destination: advert,
                                  clicks: [("someadvertiser.example", now.addingTimeInterval(5))],
                                  now: now))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
