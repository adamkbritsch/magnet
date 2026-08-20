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

print("\nRedirect navigations: the truth table")
let here = URL(string: "https://tracker.example/browse")!
let advert = URL(string: "https://someadvertiser.example/offer")!
let sameSite = URL(string: "https://tracker.example/page/2")!

func onSite(_ d: String) -> RedirectGuard.Chain { .init(appInitiated: false, anchorDomain: d) }
let appChain = RedirectGuard.Chain(appInitiated: true, anchorDomain: "tracker.example")

// THE ONE THAT WAS LEAKING. You click tracker.example/out?url=... -- same domain, an
// ordinary link -- and the server 302s you to an advertiser. Every hop looks fine.
check("an on-site redirector bouncing the window off-site is blocked",
      RedirectGuard.isRedirectAd(from: here, to: advert, scriptInitiated: true,
                                 navigationInFlight: true, chain: onSite("tracker.example")))

// The chain this must not break: the app opens a site that 302s to its own canonical
// domain. Trusted because the app asked for it.
check("a mirror redirect in an app-initiated chain is ALLOWED",
      !RedirectGuard.isRedirectAd(from: here, to: URL(string: "https://tracker-canonical.example/")!,
                                  scriptInitiated: true, navigationInFlight: true, chain: appChain))

check("a link the user clicked is honoured",
      !RedirectGuard.isRedirectAd(from: here, to: advert, scriptInitiated: false,
                                  navigationInFlight: false, chain: onSite("someadvertiser.example")))
check("and its own redirects, within where it said it went, are allowed",
      !RedirectGuard.isRedirectAd(from: here, to: URL(string: "https://someadvertiser.example/b")!,
                                  scriptInitiated: true, navigationInFlight: true,
                                  chain: onSite("someadvertiser.example")))
check("a script sending the window off-site after load is blocked",
      RedirectGuard.isRedirectAd(from: here, to: advert, scriptInitiated: true,
                                 navigationInFlight: false, chain: onSite("tracker.example")))
check("staying on the same site is allowed",
      !RedirectGuard.isRedirectAd(from: here, to: sameSite, scriptInitiated: true,
                                  navigationInFlight: false, chain: onSite("tracker.example")))
check("a subdomain of the current site is allowed",
      !RedirectGuard.isRedirectAd(from: here, to: URL(string: "https://cdn.tracker.example/x")!,
                                  scriptInitiated: true, navigationInFlight: false,
                                  chain: onSite("tracker.example")))
check("a magnet link is not treated as a redirect",
      !RedirectGuard.isRedirectAd(from: here, to: URL(string: "magnet:?xt=urn:btih:abc")!,
                                  scriptInitiated: true, navigationInFlight: false,
                                  chain: onSite("tracker.example")))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
