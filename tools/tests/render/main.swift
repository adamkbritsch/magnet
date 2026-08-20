import AppKit
import WebKit

// Two pages with deliberately opposite themes. The whole point of the feature is that
// they come out looking the same, so the test compares them against each other rather
// than against hardcoded expectations.
let lightPage = """
<html><head><style>
 body { background:#ffffff; color:#111; font-family:"Comic Sans MS"; }
 .fa { font-family:"FontAwesome" !important; }
 #chev::before { content:"\00BB"; color:#ff6b00; }
 #pseudobg::before { content:""; display:block; width:100%; height:100%;
    background-image:url(data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==); }
 #tri::after { content:""; display:inline-block; width:0; height:0;
               border:8px solid transparent; border-left-color:#ff6b00; }
 #banner { background-image:url(data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==);
           background-color:#ffcc00; }
 #seed { color:#00aa00; }
 a { color:#cc0000; }
</style></head><body>
 <a id="homelink" href="/"><img id="logo" class="site-logo" style="width:120px;height:48px"
    src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="></a>
 <div id="banner"><p id="btext">banner</p></div>
 <span id="sprite" class="icon-flag" style="display:inline-block;width:16px;height:11px;background-image:url(data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==)"></span>
 <div id="decor" style="background-image:url(data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==)">decorated</div>
 <mark id="odd">odd element</mark>
 <input id="limebtn" type="submit" value="SEARCH"
   style="background:#cde86b !important;width:180px;height:44px">
 <div id="limebox" style="background:#ffffff !important;width:200px;height:60px">x</div>
 <div id="darkbox" style="background:#1a1a1a !important;width:200px;height:60px">d</div>
 <span id="chev">chevron</span><span id="tri"></span>
 <div id="drop" style="position:absolute;top:420px;left:10px;width:220px;height:90px;background:#fff"><span>recent</span></div>
 <div id="decor2" style="position:absolute;top:560px;left:10px;width:220px;height:90px"></div>
 <div id="rounded" style="border-radius:14px;width:120px;height:48px">r</div>
 <div id="circle" style="border-radius:50%;width:40px;height:40px">c</div>
 <div id="squared" style="width:40px;height:40px">s</div>
 <div id="photobg" style="width:800px;height:400px;background-image:url(data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==)"></div>
 <div id="pseudobg" style="width:800px;height:400px"></div>
 <svg id="backdrop" width="800" height="400"><rect width="800" height="400" fill="#333"/></svg>
 <iframe id="frame" style="width:400px;height:120px;border:0"
   srcdoc="&lt;html&gt;&lt;body style=&quot;background:#ffffff;color:#111&quot;&gt;&lt;input id=&quot;fi&quot; value=&quot;x&quot;&gt;&lt;p id=&quot;fp&quot;&gt;in frame&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;"></iframe>
 <img id="poster" style="width:300px;height:450px"
      src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==">
 <p id="text">t</p><span class="fa" id="icon">x</span>
 <a id="link" href="#">link</a>
 <table><tbody><tr><td id="cell">a</td><td id="seed">99</td></tr>
  <tr><td id="longcell">Some.Very.Long.Release.Name.2026.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-GROUPNAME.Extended.Edition.mkv</td></tr>
  <tr><td id="icell" style="padding-left:34px;position:relative">
    <span style="position:absolute;left:6px;width:22px;height:12px;background:#333"></span>title</td></tr></tbody></table>
 <input id="field" value="x">
 <input id="searchfield" style="padding-left:38px" value="q">
 <img id="pic" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==">
</body></html>
"""
let darkPage = """
<html><head><style>
 body { background:#14161a; color:#eee; font-family:"Georgia"; }
 #banner { background-color:#3a0d0d; }
 a { color:#66ffcc; }
</style></head><body>
 <div id="banner"><p id="btext">banner</p></div>
 <p id="text">t</p>
 <a id="link" href="#">link</a>
 <table><tbody><tr><td id="cell">a</td><td id="seed">99</td></tr></tbody></table>
 <input id="field" value="x">
 <img id="pic" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==">
</body></html>
"""

var failures = 0
func check(_ n: String, _ c: Bool, _ got: String = "") {
    if c { print("  PASS  \(n)") } else { failures += 1; print("  FAIL  \(n)   \(got)") }
}

final class Runner: NSObject, WKNavigationDelegate {
    var done = false
    var result: [String: String] = [:]
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let js = """
        (function(){
          function s(id, prop){ var e=document.getElementById(id);
            return e ? getComputedStyle(e)[prop] : 'n/a'; }
          return JSON.stringify({
            bodyBG: getComputedStyle(document.body).backgroundColor,
            bodyFG: getComputedStyle(document.body).color,
            htmlFilter: getComputedStyle(document.documentElement).filter,
            bannerBG: s('banner','backgroundColor'),
            bannerImg: s('banner','backgroundImage'),
            bannerTextFG: s('btext','color'),
            seedFG: s('seed','color'),
            linkFG: s('link','color'),
            textFont: s('text','fontFamily'),
            iconFont: s('icon','fontFamily'),
            cellPad: s('cell','paddingTop'),
            dropBG: s('drop','backgroundColor'),
            limeBtnBG: s('limebtn','backgroundColor'),
            limeBoxBG: s('limebox','backgroundColor'),
            darkBoxBG: s('darkbox','backgroundColor'),
            scheme: getComputedStyle(document.documentElement).colorScheme,
            backdropDisp: s('backdrop','display'),
            photoBG: s('photobg','backgroundImage'),
            pseudoBG: (function(){ var e=document.getElementById('pseudobg');
              return e ? getComputedStyle(e,'::before').backgroundImage : 'n/a'; })(),
            posterDisp: s('poster','display'),
            decorBG2: s('decor2','backgroundColor'),
            roundedR: s('rounded','borderTopLeftRadius'),
            circleR: s('circle','borderTopLeftRadius'),
            squaredR: s('squared','borderTopLeftRadius'),
            chevColor: (function(){ var e=document.getElementById('chev');
              return e ? getComputedStyle(e,'::before').color : 'n/a'; })(),
            triLeft: (function(){ var e=document.getElementById('tri');
              return e ? getComputedStyle(e,'::after').borderLeftColor : 'n/a'; })(),
            triTop: (function(){ var e=document.getElementById('tri');
              return e ? getComputedStyle(e,'::after').borderTopColor : 'n/a'; })(),
            iconCellPadLeft: s('icell','paddingLeft'),
            searchPadLeft: s('searchfield','paddingLeft'),
            cellLineHeight: s('cell','lineHeight'),
            cellWrap: s('cell','overflowWrap'),
            frameBG: (function(){ try {
              var f=document.getElementById('frame');
              var d=f && (f.contentDocument || (f.contentWindow||{}).document);
              return d && d.body ? getComputedStyle(d.body).backgroundColor : 'no-doc';
            } catch(e) { return 'blocked'; } })(),
            frameFG: (function(){ try {
              var f=document.getElementById('frame');
              var d=f && (f.contentDocument || (f.contentWindow||{}).document);
              var p=d && d.getElementById('fp');
              return p ? getComputedStyle(p).color : 'no-el';
            } catch(e) { return 'blocked'; } })(),
            pageScrollW: String(document.documentElement.scrollWidth),
            pageClientW: String(document.documentElement.clientWidth),
            inputBG: s('field','backgroundColor'),
            imgFilter: s('pic','filter'),
            host: document.documentElement.getAttribute('data-x-host') || '',
            oddFG: s('odd','color'),
            spriteBG: s('sprite','backgroundImage'),
            decorBG: s('decor','backgroundImage'),
            logoDisplay: s('logo','display'),
            markText: (document.querySelector('.x-wordmark') || {}).textContent || '',
            markHeight: (document.querySelector('.x-wordmark') ? getComputedStyle(document.querySelector('.x-wordmark')).height : ''),
            markWidth: (document.querySelector('.x-wordmark') ? getComputedStyle(document.querySelector('.x-wordmark')).width : ''),
            markFontPx: (document.querySelector('.x-wordmark') ? getComputedStyle(document.querySelector('.x-wordmark')).fontSize : ''),
            markFits: (function(){
              var m = document.querySelector('.x-wordmark'); if (!m) return 'no-mark';
              var a = document.getElementById('homelink'); if (!a) return 'no-link';
              var mr = m.getBoundingClientRect(), ar = a.getBoundingClientRect();
              var slack = 1.5;
              return (mr.left >= ar.left - slack && mr.right <= ar.right + slack &&
                      mr.top >= ar.top - slack && mr.bottom <= ar.bottom + slack)
                     ? 'inside' : 'spills';
            })(),
            markTextFills: (function(){
              var m = document.querySelector('.x-wordmark'); if (!m) return '0';
              return String(Math.round(m.scrollWidth));
            })(),
            markInLink: String(!!(document.querySelector('.x-wordmark') && document.querySelector('.x-wordmark').closest('a'))),
            homelink: String(!!document.getElementById('homelink'))
          });
        })();
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            w.evaluateJavaScript(js) { v, _ in
                if let s = v as? String, let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] { self.result = o }
                self.done = true
            }
        }
    }
}

func run(_ html: String, css: String = SiteStyle.defaultCSS) -> [String: String] {
    let cfg = WKWebViewConfiguration()
    if let s = SiteStyle.userScript(css: css) { cfg.userContentController.addUserScript(s) }
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 600), configuration: cfg)
    let r = Runner(); w.navigationDelegate = r
    w.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
    let deadline = Date().addingTimeInterval(20)
    while !r.done && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    return r.result
}

let l = run(lightPage)
let d = run(darkPage)

print("Uniformity — a light site and a dark site must end up identical")
for (key, label) in [("bodyBG", "page background"), ("bodyFG", "text colour"),
                     ("linkFG", "link colour"), ("bannerBG", "panel background"),
                     ("cellPad", "table rhythm"), ("inputBG", "input background"),
                     ("textFont", "typeface")] {
    check("\(label) matches across both sites", l[key] == d[key], "\(l[key] ?? "?") vs \(d[key] ?? "?")")
}

print("\nThe theme is actually imposed, not merely inherited")
check("page is dark", (l["bodyBG"] ?? "").contains("15, 17, 19"), l["bodyBG"] ?? "")
check("a light site's white background is gone", l["bodyBG"] != "rgb(255, 255, 255)", l["bodyBG"] ?? "")
check("a panel's own colour is overridden", l["bannerBG"] == "rgba(0, 0, 0, 0)", l["bannerBG"] ?? "")
check("a panel's background image is removed", l["bannerImg"] == "none", l["bannerImg"] ?? "")
check("text inside a panel is themed", l["bannerTextFG"] == l["bodyFG"], l["bannerTextFG"] ?? "")
check("a site's own text colour is overridden", l["seedFG"] == l["bodyFG"], l["seedFG"] ?? "")
check("links get the accent, not the site's colour",
      (l["linkFG"] ?? "").contains("122, 162, 247"), l["linkFG"] ?? "")

print("\nFunctionality and artwork survive")
check("NO filter on the page, so position:fixed still works",
      (l["htmlFilter"] ?? "none") == "none", l["htmlFilter"] ?? "")
check("artwork is untouched", (l["imgFilter"] ?? "none") == "none", l["imgFilter"] ?? "")
check("icon fonts preserved", (l["iconFont"] ?? "").contains("FontAwesome"), l["iconFont"] ?? "")
check("site typeface replaced", !(l["textFont"] ?? "").contains("Comic Sans"), l["textFont"] ?? "")
check("and on the dark site too", !(d["textFont"] ?? "").contains("Georgia"), d["textFont"] ?? "")
check("hostname stamped for per-site exceptions", !(l["host"] ?? "").isEmpty, l["host"] ?? "")

print("\nInline !important is the one thing an author rule cannot beat")
// A site's own button colour set inline with !important outranks every rule in the
// stylesheet however specific. It has to be overridden by enforcement, not by CSS.
check("a lime submit button set inline-!important is overridden",
      (l["limeBtnBG"] ?? "").contains("28, 32, 38"), l["limeBtnBG"] ?? "")
check("a white panel set inline-!important is overridden",
      (l["limeBoxBG"] ?? "").contains("22, 25, 29"), l["limeBoxBG"] ?? "")

print("\nFramed content is themed too, or a widget keeps the site's colours")
// LimeTorrents' entire search box lives in an iframe. A main-frame-only injection
// leaves it wearing the site's own white field and green button.
check("an iframe's body gets the page background",
      (l["frameBG"] ?? "").contains("15, 17, 19"), l["frameBG"] ?? "")
check("text inside a frame gets the theme colour",
      (l["frameFG"] ?? "").contains("231, 233, 236"), l["frameFG"] ?? "")

print("\nAn overlay must stay opaque, or the page reads through it")
// Stripping backgrounds to transparent is right for layout containers and wrong for a
// dropdown drawn on top of the page.
check("a positioned panel with content gets an opaque surface",
      (l["dropBG"] ?? "").contains("22, 25, 29"), l["dropBG"] ?? "")
check("a positioned DECORATION is left transparent",
      l["decorBG2"] == "rgba(0, 0, 0, 0)", l["decorBG2"] ?? "")

print("\nFull-bleed decorative artwork goes; content artwork stays")
// The case that prompted this was a STATIC inline <svg> spanning a whole hero, so the
// test is size and emptiness, not position. Cover art is nowhere near that big.
check("a viewport-sized empty graphic is hidden", l["backdropDisp"] == "none", l["backdropDisp"] ?? "")
check("a poster-sized image is untouched", l["posterDisp"] != "none", l["posterDisp"] ?? "")
// An empty div is exactly how a photographic backdrop is usually hung, and the icon
// exemption spares empty elements -- so size has to override that exemption.
check("a full-bleed background on an EMPTY div is removed",
      l["photoBG"] == "none", l["photoBG"] ?? "")
// No CSS rule here reaches a pseudo-element's background-image at all.
check("a full-bleed background on a PSEUDO-element is removed",
      l["pseudoBG"] == "none", l["pseudoBG"] ?? "")
check("a small sprite icon still keeps its background",
      (l["spriteBG"] ?? "none") != "none", l["spriteBG"] ?? "")

print("\nCorners belong to the theme, but a shape is not a corner")
check("a rounded element takes the theme radius", l["roundedR"] == "6px", l["roundedR"] ?? "")
// 14px on a 48px-tall box is a corner treatment; 20px would be a pill, and a pill is a
// shape rather than a corner, so it is deliberately left alone.
check("a pill keeps its shape",
      (l["circleR"] ?? "") != "6px", l["circleR"] ?? "")
check("a circular element is NOT squared off", l["circleR"] != "6px", l["circleR"] ?? "")
check("a square element is not rounded", l["squaredR"] == "0px", l["squaredR"] ?? "")

print("\nPseudo-elements carry the site accent and must be overridden too")
// A list marker is almost always ::before { content:"\u{BB}"; color:<brand> }, and
// pseudo-elements were exempt from the whole override.
check("a ::before glyph loses the site accent",
      l["chevColor"] == l["bodyFG"], l["chevColor"] ?? "")
// A triangle is four borders with three transparent. Recolouring all four fills it in.
check("a CSS triangle's painted edge is recoloured",
      (l["triLeft"] ?? "").contains("231, 233, 236"), l["triLeft"] ?? "")
check("SHAPE PRESERVED: its transparent edges stay transparent",
      (l["triTop"] ?? "").contains(", 0)") || l["triTop"] == "transparent", l["triTop"] ?? "")

print("\nREGRESSION: insets a site reserves for its own artwork are left alone")
// Hit three times now -- a search field's padding-left clears a magnifier icon, and a
// listing cell's padding-left clears its category icon. Replacing either drops the
// icon straight on top of the text.
check("a cell's left inset survives", l["iconCellPadLeft"] == "34px", l["iconCellPadLeft"] ?? "")
check("a search field's left inset survives", l["searchPadLeft"] == "38px", l["searchPadLeft"] ?? "")
// Both of these reflow a row the site sized for one line of its own type.
check("line-height is not forced onto cells",
      (l["cellLineHeight"] ?? "") != "1.5" && !(l["cellLineHeight"] ?? "").hasPrefix("24"),
      l["cellLineHeight"] ?? "")
// Wrapping in cells is deliberate: without it a long unbroken release name widens the
// table and the whole page scrolls sideways. The row collision that once justified
// removing it came from the forced line-height, which is gone.
check("cells DO wrap, so a long name cannot widen the page",
      l["cellWrap"] == "break-word", l["cellWrap"] ?? "")
let sw = Int(l["pageScrollW"] ?? "0") ?? 0, cw = Int(l["pageClientW"] ?? "0") ?? 0
check("NO HORIZONTAL SCROLL with a 120-character unbroken release name",
      sw <= cw + 1, "scrollWidth \(sw) vs clientWidth \(cw)")

print("\nThe override reaches EVERY element, not a list of them")
check("an arbitrary element is themed too", l["oddFG"] == l["bodyFG"], l["oddFG"] ?? "")

print("\nBackground images: decoration goes, content stays")
// An element with content of its own has a decorative background; an empty one IS its
// background, so removing it would delete information rather than restyle it.
check("decorative background removed", l["decorBG"] == "none", l["decorBG"] ?? "")
check("sprite icon keeps its background", (l["spriteBG"] ?? "none") != "none", l["spriteBG"] ?? "")

print("\nThe logo becomes text at the same height")
check("logo image hidden", l["logoDisplay"] == "none", l["logoDisplay"] ?? "")
check("wordmark inserted", !(l["markText"] ?? "").isEmpty, "none inserted")
check("named from the hostname", l["markText"] == "Example", l["markText"] ?? "")
check("occupies the image's exact box (120x48)",
      l["markWidth"] == "120px" && l["markHeight"] == "48px",
      "\(l["markWidth"] ?? "?") x \(l["markHeight"] ?? "?")")
check("text scaled to fill that width",
      (Int(l["markTextFills"] ?? "0") ?? 0) >= 112 && (Int(l["markTextFills"] ?? "0") ?? 0) <= 124,
      "text width \(l["markTextFills"] ?? "?") of 120")
// A short name fitted purely to width would scale up until it collided with whatever
// sits above and below it, so the fit is capped by the original height.
check("never taller than the image it replaced",
      (Double((l["markFontPx"] ?? "0").replacingOccurrences(of: "px", with: "")) ?? 99) <= 48 * 0.82 + 0.5,
      "font-size \(l["markFontPx"] ?? "?") vs cap \(48 * 0.82)")
check("NO OVERLAP: stays within the link's box", l["markFits"] == "inside", l["markFits"] ?? "")
check("still inside the link, so it still goes home",
      l["markInLink"] == "true", l["markInLink"] ?? "")
check("the link itself survived", l["homelink"] == "true", l["homelink"] ?? "")

print("\nA LIGHT theme must invert the machinery, not break under it")
// The enforcement sweep used to hard-code "lighter than 70 is the site's". Under a
// light palette that is every surface including ours, so it now measures against the
// page colour instead.
let paper = run(lightPage, css: SiteStyle.css(for: "paper"))
check("the page is light", (paper["bodyBG"] ?? "").contains("245, 243, 238"), paper["bodyBG"] ?? "")
check("text is dark", (paper["bodyFG"] ?? "").contains("28, 27, 24"), paper["bodyFG"] ?? "")
check("colour-scheme follows the theme", (paper["scheme"] ?? "").contains("light"), paper["scheme"] ?? "")
check("a site's DARK inline-!important panel is overridden toward light",
      (paper["darkBoxBG"] ?? "") != "rgb(26, 26, 26)", paper["darkBoxBG"] ?? "")
// The sweep must not eat the theme's own surfaces, which are lighter than the page.
check("our own light surfaces survive the sweep",
      (paper["dropBG"] ?? "").contains("255, 255, 255"), paper["dropBG"] ?? "")
check("icon fonts still preserved under a light theme",
      (paper["iconFont"] ?? "").contains("FontAwesome"), paper["iconFont"] ?? "")
check("a light theme differs from the dark one",
      paper["bodyBG"] != l["bodyBG"] && paper["linkFG"] != l["linkFG"],
      "\(paper["bodyBG"] ?? "") / \(paper["linkFG"] ?? "")")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
