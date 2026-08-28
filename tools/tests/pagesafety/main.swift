import AppKit
import WebKit

// The blocker must never eat the page.
//
// A well-meant anti-adblock "wall breaker" once hid any large, high-z-index,
// positioned element -- which is an exact description of a site's own content
// wrapper. Every site rendered blank, with no error to explain it, and nothing in the
// app said anything was wrong. Shape does not distinguish a wall from a layout, and
// the cost of guessing wrong is the whole page.
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

// Shaped like the real thing: a full-size positioned wrapper holding the content,
// with genuine ads among it.
let page = """
<html><head><style>
 body { margin:0 }
 #wrap { position:absolute; top:0; left:0; width:100%; height:100%; z-index:200; background:#111 }
 #inner { padding:20px; color:#eee }
 table { width:100% }
 #sticky { position:fixed; top:0; left:0; width:100%; height:60px; z-index:999; background:#222 }
</style></head><body>
 <div id="sticky">site nav</div>
 <iframe id="turnstile" src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x"
    style="width:300px;height:65px;border:0"></iframe>
 <iframe id="turnstile2" src="https://challenges.cloudflare.com/turnstile/v0/x"
    style="width:302px;height:77px;border:0"></iframe>
 <iframe id="hcaptcha" src="https://hcaptcha.com/captcha/v1/x"
    style="width:302px;height:76px;border:0"></iframe>
 <div id="wrap"><div id="inner">
   <h1 id="title">Tracker</h1>
   <table id="listing"><tr><td id="row1">Some.Release.2026.1080p</td></tr></table>
   <img id="poster" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" style="width:300px;height:450px">
   <img id="ownbanner" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" style="width:728px;height:90px">
   <a id="realad" href="https://advertiser.example/x"><img id="adimg"
      src="https://advertiser.example/banner.gif" style="width:300px;height:250px"></a>
   <iframe id="adframe" src="https://advertiser.example/frame" style="width:728px;height:90px"></iframe>
 </div></div>
</body></html>
"""

@MainActor
final class R: NSObject, WKNavigationDelegate {
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(a.request.url?.host == "advertiser.example" ? .cancel : .allow)
    }
}

MainActor.assumeIsolated {
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.addUserScript(BannerBlocker.userScript())
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
    let r = R(); w.navigationDelegate = r
    w.loadHTMLString(page, baseURL: URL(string: "https://tracker.test/browse")!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated {
        let js = """
        (function(){
          function vis(id){ var e=document.getElementById(id); if(!e) return 'gone';
            if(getComputedStyle(e).display==='none') return 'hidden';
            var r=e.getBoundingClientRect();
            return (r.width>0&&r.height>0) ? 'visible' : 'hidden'; }
          return JSON.stringify({wrap:vis('wrap'), inner:vis('inner'), title:vis('title'),
            listing:vis('listing'), row1:vis('row1'), poster:vis('poster'),
            sticky:vis('sticky'), ownbanner:vis('ownbanner'),
            realad:vis('realad'), adframe:vis('adframe'),
            turnstile:vis('turnstile'), turnstile2:vis('turnstile2'),
            hcaptcha:vis('hcaptcha')});
        })();
        """
        w.evaluateJavaScript(js) { v, _ in
            guard let s = v as? String, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: String]
            else { print("  FAIL  probe did not run"); exit(1) }

            print("The page survives the blocker")
            // The wrapper is the case that blanked every site.
            check("a full-size positioned content wrapper survives", o["wrap"] == "visible",
                  o["wrap"] ?? "?")
            check("and everything inside it", o["inner"] == "visible" && o["title"] == "visible"
                  && o["listing"] == "visible" && o["row1"] == "visible")
            check("a poster is not an advert", o["poster"] == "visible", o["poster"] ?? "?")
            check("the site's OWN wide banner stays", o["ownbanner"] == "visible", o["ownbanner"] ?? "?")
            check("a fixed site header stays", o["sticky"] == "visible", o["sticky"] ?? "?")

            // The one that stopped the whole app: Turnstile is an off-domain iframe
            // about 300x65, and 300/65 is 4.6 -- wide and short, which the leaderboard
            // rule read as an advert. Hidden, the challenge cannot be answered, so
            // every protected site spins on "Performing security verification" for
            // ever. A verifier is never an advert, whatever shape it is.
            print("\nAnything that verifies you are not a robot survives")
            check("Cloudflare Turnstile (300x65) survives", o["turnstile"] == "visible",
                  o["turnstile"] ?? "?")
            check("Turnstile at its other size survives", o["turnstile2"] == "visible",
                  o["turnstile2"] ?? "?")
            check("hCaptcha survives", o["hcaptcha"] == "visible", o["hcaptcha"] ?? "?")

            print("\nAnd the adverts do not")
            check("an offsite 300x250 box is hidden", o["realad"] == "hidden", o["realad"] ?? "?")
            check("an offsite iframe leaderboard is hidden", o["adframe"] == "hidden", o["adframe"] ?? "?")

            print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
            exit(failures == 0 ? 0 : 1)
        }
    } }
    RunLoop.main.run(until: Date().addingTimeInterval(40))
    print("  FAIL  timed out"); exit(1)
}
