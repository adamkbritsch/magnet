import Foundation
import WebKit

/// Hides self-hosted banner ads, which filter lists structurally cannot catch.
///
/// EasyList and friends block ad NETWORKS by hostname. A tracker's own affiliate
/// banner is served from the tracker's own domain, so no list contains it and no
/// amount of filter updating will.
///
/// What gives it away is shape and destination: display banners are standardised —
/// 728x90, 970x90, 468x60, 320x50 — so they are wide and short in a way real content
/// is not, and they point somewhere else. A poster is tall, a screenshot is roughly
/// square, and neither leaves the site. Requiring BOTH conditions is what keeps a
/// site's own wide announcement banner visible.
///
/// Independent of the restyling: this runs whether or not a theme is applied.
enum BannerBlocker {
    /// Standard display-ad ratios start around 5:1; 3 is deliberately generous while
    /// still far from any poster or screenshot.
    static let minRatio = 3.0
    static let minWidth = 300.0

    static func userScript() -> WKUserScript {
        let source = """
        (function () {
          function reg(host) {
            var h = String(host || '').toLowerCase();
            if (h.indexOf('www.') === 0) h = h.slice(4);
            var p = h.split('.');
            if (p.length >= 3 && p[p.length - 2].length <= 3 && p[p.length - 1].length <= 3) {
              return p.slice(-3).join('.');
            }
            return p.length >= 2 ? p.slice(-2).join('.') : h;
          }

          var pageDomain = reg(location.hostname);

          function offsite(url) {
            if (!url) return false;
            try {
              var u = new URL(url, location.href);
              if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
              return reg(u.hostname) !== pageDomain;
            } catch (e) { return false; }
          }

          function sweep() {
            var imgs = document.images;
            for (var i = 0; i < imgs.length; i++) {
              var im = imgs[i];
              if (im.getAttribute('data-x-banner')) continue;
              var r = im.getBoundingClientRect();
              if (r.width < \(Int(minWidth)) || r.height < 20) continue;
              if (r.width / r.height < \(minRatio)) continue;

              var link = im.closest ? im.closest('a') : null;
              // Either the destination or the artwork itself belongs to someone else.
              var leaves = (link && offsite(link.getAttribute('href')))
                        || offsite(im.getAttribute('src'));
              if (!leaves) continue;

              im.setAttribute('data-x-banner', '1');
              var kill = link || im;
              kill.style.setProperty('display', 'none', 'important');
            }
          }

          function start() {
            try { sweep(); } catch (e) {}
            if (window.MutationObserver && !document.documentElement.getAttribute('data-x-bwatch')) {
              document.documentElement.setAttribute('data-x-bwatch', '1');
              var t = null;
              new MutationObserver(function () {
                if (t) clearTimeout(t);
                // Banners are commonly injected after load, and rotated afterwards.
                t = setTimeout(function () { try { sweep(); } catch (e) {} }, 150);
              }).observe(document.documentElement, { childList: true, subtree: true });
            }
          }

          document.addEventListener('DOMContentLoaded', start);
          window.addEventListener('load', start);
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentEnd,
                            forMainFrameOnly: false)
    }
}
