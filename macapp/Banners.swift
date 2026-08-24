import Foundation
import WebKit

/// Decides what happens to a top-level navigation.
///
/// Two heuristics were tried and both were outflanked, so this inverts the model: it
/// is an ALLOW-LIST. Anything leaving the sites you actually use is stopped unless you
/// ask for it twice. A block-list can only ever chase the current technique --
/// `window.open`, a scripted `location`, an on-site redirector 302ing out, a link that
/// simply lies about where it goes -- and each fix reaches exactly the one variant it
/// was written for. The set of places you meant to visit is small and knowable; the
/// set of tricks is not.
///
/// The cost is real and deliberate: a genuine outbound link is stopped too, the first
/// time. A dialog asks; a host approved there is not asked about again this session.
///
/// Why a dialog, and not click-it-again: the click-again design was bypassed in the
/// wild. "Clicked" is not evidence of a person -- a script calling click() on an
/// anchor it just made reports as a link activation, indistinguishable from a real
/// one -- and the confirmation state it armed was honoured for ANY later navigation
/// to the same URL. So an advert fired twice and confirmed itself. A modal dialog is
/// the one surface a page cannot click.
enum RedirectGuard {
    enum Decision: Equatable {
        /// Somewhere you know, or somewhere you approved.
        case allow
        /// Leaving for somewhere unknown with no person behind it, or somewhere
        /// already refused this session.
        case block
        /// A link activation leaving for somewhere unknown: put the question to a
        /// person, in a dialog the page cannot answer.
        case confirm
    }

    struct Chain {
        /// True when the app asked for the navigation. Trusted through every redirect,
        /// which is what lets a mirror 302 to its canonical domain.
        var appInitiated: Bool
        /// The registrable domain the chain was aimed at. Redirects may move within it.
        var anchorDomain: String?
    }

    /// - Parameters:
    ///   - known: registrable domains of the sites in the bar, plus their mirrors.
    ///   - approved: domains a person approved in the dialog this session.
    ///   - denied: domains a person refused in the dialog this session. Blocked
    ///     silently from then on, so a hijack firing on every click does not turn
    ///     into a dialog on every click.
    static func decide(from current: URL?,
                       to destination: URL,
                       navigationType: NavigationKind,
                       chain: Chain,
                       known: Set<String>,
                       approved: Set<String>,
                       denied: Set<String>) -> Decision {
        guard let scheme = destination.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let destHost = destination.host else { return .allow }
        let dest = registrableDomain(destHost)

        // The app asked for it, and so did every redirect it triggers.
        if chain.appInitiated { return .allow }
        // Somewhere already refused. Refusal outranks everything a page can arrange,
        // because everything below this line is drawn from what pages do.
        if denied.contains(dest) { return .block }
        // Where the chain was aimed, including that site's own redirects.
        if let anchor = chain.anchorDomain, anchor == dest { return .allow }
        // Still on the site being read.
        if let current, let host = current.host, registrableDomain(host) == dest { return .allow }
        // A site in the bar, or one of its mirrors: somewhere you already go.
        if known.contains(dest) { return .allow }
        // Somewhere a person already said yes to, in the dialog.
        if approved.contains(dest) { return .allow }

        // Leaving for somewhere unknown. A link activation earns the question -- even
        // a scripted one, since the dialog is where the person answers -- and a page
        // moving itself outright earns nothing.
        return navigationType == .userLink ? .confirm : .block
    }

    /// Whether a real pointer was recently on a link to this destination.
    ///
    /// WebKit reports a script calling click() on an anchor as a link activation --
    /// there is no way to tell it from a person at the navigation layer. The page's
    /// own event system CAN tell: `event.isTrusted` is set by the engine and cannot
    /// be forged, so a capture-phase listener records what real clicks actually
    /// landed on. A "link activation" with no matching real click behind it is a
    /// script navigation wearing a costume, and is judged as one.
    ///
    /// Matching is by registrable domain rather than exact URL: sites rewrite their
    /// outbound hrefs in flight (tracking parameters, http to https), and the domain
    /// is the part that decides anything here anyway.
    static func clickMatches(destination: URL,
                             clicks: [(domain: String, at: Date)],
                             now: Date,
                             window: TimeInterval = 2.0) -> Bool {
        guard let host = destination.host else { return false }
        let dest = registrableDomain(host)
        return clicks.contains { click in
            click.domain == dest && now.timeIntervalSince(click.at) <= window
                && now.timeIntervalSince(click.at) >= 0
        }
    }

    /// What started the navigation, reduced to what actually matters here.
    enum NavigationKind {
        /// A link the user clicked, or a form they submitted.
        case userLink
        /// Back, forward, reload: always the user, never an advert.
        case history
        /// Script, meta refresh, or a server redirect.
        case script
    }
}

/// Records what real clicks land on, from inside the page.
///
/// Runs in its own content world: the page cannot see the listeners, and -- the part
/// that matters -- cannot reach the message handler to forge a click. A hostile page
/// in the shared world could simply call postMessage itself and invent a trusted
/// click on any URL it liked.
enum TrustedClicks {
    static let handlerName = "magnetTrustedClick"

    static func userScript() -> WKUserScript {
        let source = """
        (function () {
          function report(e) {
            if (!e.isTrusted) return;
            if (e.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
            var el = (e.composedPath ? e.composedPath()[0] : e.target);
            var a = el && el.closest ? el.closest('a[href]') : null;
            if (!a) return;
            var href = '';
            try { href = new URL(a.getAttribute('href'), location.href).href; } catch (err) {}
            if (!href) return;
            try { window.webkit.messageHandlers.\(handlerName).postMessage(href); } catch (err) {}
          }
          var opts = { capture: true, passive: true };
          document.addEventListener('mousedown', report, opts);
          document.addEventListener('click', report, opts);
          document.addEventListener('auxclick', report, opts);
          document.addEventListener('keydown', report, opts);
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: false,
                            in: .defaultClient)
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
