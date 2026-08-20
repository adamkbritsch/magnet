import Foundation
import WebKit

/// Decides whether a navigation is a redirect ad.
///
/// These hijack NAVIGATION rather than inject content, so no filter list or stylesheet
/// reaches them. Judged per CHAIN rather than per hop, because the technique that
/// defeats a per-hop rule is the one these sites actually use: an on-site redirector.
/// You click `site.example/out?url=...`, which is the same domain and therefore a
/// perfectly ordinary link, and the SERVER then 302s you somewhere else entirely. Every
/// individual hop looks defensible; only the chain gives it away.
///
/// Pure, and separate from the web view, so the truth table can be tested directly --
/// the cost of an over-eager rule here is a browser that refuses to go places.
enum RedirectGuard {
    /// Where a navigation chain came from, carried across its redirects.
    struct Chain {
        /// True when the app asked for this navigation: opening a chip, switching to a
        /// mirror. Those chains are trusted through every redirect, which is what keeps
        /// a site that 302s to its canonical domain working.
        var appInitiated: Bool
        /// The registrable domain the chain was aimed at -- the href the user clicked,
        /// or the URL the app requested. A chain is allowed to move within this.
        var anchorDomain: String?
    }

    static func isRedirectAd(from current: URL?,
                             to destination: URL,
                             scriptInitiated: Bool,
                             navigationInFlight: Bool,
                             chain: Chain) -> Bool {
        guard let scheme = destination.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let destHost = destination.host else { return false }
        let dest = registrableDomain(destHost)

        // The app asked for it, and so did every redirect it triggers.
        if chain.appInitiated { return false }

        // A link the user actually clicked is honoured -- but only to where it SAID it
        // went. This is the hop that matters: the click is allowed, and the 302 that
        // follows it out of that domain is not.
        if !scriptInitiated {
            return false
        }

        // Same site: pagination, search, login, the site's own interstitials.
        if let current, let currentHost = current.host,
           registrableDomain(currentHost) == dest { return false }

        // Still inside whatever the user aimed at, including its own redirects.
        if let anchor = chain.anchorDomain, anchor == dest { return false }

        // A script or a redirect taking the window somewhere nobody asked for.
        _ = navigationInFlight
        return true
    }
}

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

          // A full-window transparent link. The whole page becomes one advert: any
          // click is a real link activation, so it looks entirely legitimate to a
          // navigation policy and only its SHAPE gives it away -- covering the view,
          // holding nothing, and leaving the site.
          function sweepCatchers() {
            var vw = window.innerWidth || 1280, vh = window.innerHeight || 800;
            var links = document.querySelectorAll('a');
            for (var i = 0; i < links.length; i++) {
              var a = links[i];
              if (a.getAttribute('data-x-catcher')) continue;
              var r = a.getBoundingClientRect();
              if (r.width < vw * 0.55 || r.height < vh * 0.55) continue;
              // Real content that big has text or pictures in it.
              if ((a.textContent || '').trim().length > 0) continue;
              if (a.querySelector('img, video, svg, picture')) continue;
              var cs = getComputedStyle(a);
              if (cs.position !== 'absolute' && cs.position !== 'fixed') continue;
              a.setAttribute('data-x-catcher', '1');
              a.style.setProperty('display', 'none', 'important');
            }
          }

          function sweep() {
            sweepCatchers();
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
