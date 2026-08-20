import Foundation
import WebKit

/// Injects one stylesheet into every page so sites read consistently.
///
/// Unifies typeface, line height, table density and form controls, then darkens the
/// page by inversion. Nothing is hidden and no element is repositioned.
///
/// The theme is imposed rather than inverted. Inversion was tried first and was the
/// wrong tool twice over: it gives every site a different palette (its own, flipped)
/// when the goal is one palette everywhere, and it turns an already-dark site into
/// glare. Painting a scheme also avoids a `filter` on `html`, which would establish a
/// containing block and stop `position: fixed` working.
///
/// Backgrounds and colours are overridden wholesale. Layout, spacing and behaviour are
/// not touched, so functionality survives; the per-site escape hatch at the bottom of
/// the stylesheet covers anything this does not suit.
enum SiteStyle {
    /// The rule that makes this safe.
    ///
    /// Font family is set on CONTAINER elements only -- never on `*`, `span` or `i`.
    /// Icon fonts (Font Awesome, Glyphicons, Material Icons) work by declaring a
    /// font-family on the icon element itself, and a declared value always beats an
    /// inherited one. So inheritance unifies ordinary text while icons keep rendering
    /// as icons. A `*` selector, or `!important` on the icon elements, turns every
    /// icon on the page into a stray letter.
    /// A palette. Every theme must define the full token set, or a rule referencing a
    /// missing one is simply dropped and that part of the page keeps the site's look.
    struct Theme: Identifiable, Equatable {
        let id: String
        let name: String
        /// One-line description, shown in Settings.
        let blurb: String
        /// Swatches for the picker: page, surface, accent.
        let swatches: [String]
        /// The `:root` block, including `color-scheme`.
        let tokens: String
    }

    static let themes: [Theme] = [
        Theme(id: "slate", name: "Slate",
              blurb: "Neutral and low contrast.",
              swatches: ["#0f1113", "#16191d", "#7aa2f7"],
              tokens: #"""
              :root {
                color-scheme: dark;
                --x-radius: 6px;
                --x-bg: #0f1113;
                --x-surface: #16191d;
                --x-surface-2: #1c2026;
                --x-raised: #262c34;
                --x-fg: #e7e9ec;
                --x-muted: #9aa1a9;
                --x-link: #7aa2f7;
                --x-link-hover: #a6c1ff;
                --x-border: rgba(255, 255, 255, 0.10);
                --x-rule: rgba(255, 255, 255, 0.10);
                --x-zebra: rgba(255, 255, 255, 0.03);
                --x-hover: rgba(255, 255, 255, 0.07);
              }
              """#),

        Theme(id: "midnight", name: "Midnight",
              blurb: "Deep navy, softer edges.",
              swatches: ["#0b1020", "#141a2e", "#8b9cff"],
              tokens: #"""
              :root {
                color-scheme: dark;
                --x-radius: 10px;
                --x-bg: #0b1020;
                --x-surface: #141a2e;
                --x-surface-2: #1b2340;
                --x-raised: #263054;
                --x-fg: #e4e8f5;
                --x-muted: #99a2c4;
                --x-link: #8b9cff;
                --x-link-hover: #b3bdff;
                --x-border: rgba(160, 175, 255, 0.16);
                --x-rule: rgba(160, 175, 255, 0.14);
                --x-zebra: rgba(160, 175, 255, 0.05);
                --x-hover: rgba(160, 175, 255, 0.10);
              }
              """#),

        Theme(id: "carbon", name: "Carbon",
              blurb: "True black and sharp. Easiest on an OLED display.",
              swatches: ["#000000", "#0c0c0c", "#ffb454"],
              tokens: #"""
              :root {
                color-scheme: dark;
                --x-radius: 2px;
                --x-bg: #000000;
                --x-surface: #0c0c0c;
                --x-surface-2: #141414;
                --x-raised: #1f1f1f;
                --x-fg: #f2f2f2;
                --x-muted: #8f8f8f;
                --x-link: #ffb454;
                --x-link-hover: #ffcd8a;
                --x-border: rgba(255, 255, 255, 0.14);
                --x-rule: rgba(255, 255, 255, 0.12);
                --x-zebra: rgba(255, 255, 255, 0.04);
                --x-hover: rgba(255, 180, 84, 0.12);
              }
              """#),

        Theme(id: "forest", name: "Forest",
              blurb: "Green-tinted and muted.",
              swatches: ["#0d1410", "#131c15", "#7fd18a"],
              tokens: #"""
              :root {
                color-scheme: dark;
                --x-radius: 6px;
                --x-bg: #0d1410;
                --x-surface: #131c15;
                --x-surface-2: #19251d;
                --x-raised: #22322a;
                --x-fg: #e2ebe3;
                --x-muted: #91a795;
                --x-link: #7fd18a;
                --x-link-hover: #a8e5af;
                --x-border: rgba(160, 220, 175, 0.14);
                --x-rule: rgba(160, 220, 175, 0.12);
                --x-zebra: rgba(160, 220, 175, 0.04);
                --x-hover: rgba(160, 220, 175, 0.09);
              }
              """#),

        Theme(id: "paper", name: "Paper",
              blurb: "Light. Warm off-white with dark text.",
              swatches: ["#f5f3ee", "#ffffff", "#0f6d63"],
              tokens: #"""
              :root {
                color-scheme: light;
                --x-radius: 8px;
                --x-bg: #f5f3ee;
                --x-surface: #ffffff;
                --x-surface-2: #ebe8e1;
                --x-raised: #e0dcd2;
                --x-fg: #1c1b18;
                --x-muted: #6b675e;
                --x-link: #0f6d63;
                --x-link-hover: #0a4f48;
                --x-border: rgba(0, 0, 0, 0.14);
                --x-rule: rgba(0, 0, 0, 0.12);
                --x-zebra: rgba(0, 0, 0, 0.035);
                --x-hover: rgba(0, 0, 0, 0.07);
              }
              """#),
    ]

    static let customThemeID = "custom"

    /// Typeface tokens are shared: they are not what distinguishes a theme.
    private static let fonts = #"""
    :root {
      --x-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto,
                "Helvetica Neue", Arial, sans-serif;
      --x-mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    """#

    static func theme(_ id: String) -> Theme {
        themes.first { $0.id == id } ?? themes[0]
    }

    /// A complete stylesheet: one palette over the shared structure.
    static func css(for id: String) -> String {
        fonts + "\n" + theme(id).tokens + "\n" + structure
    }

    /// The stylesheet everything shares once a palette is chosen.
    static var defaultCSS: String { css(for: themes[0].id) }

    private static let structure = #"""
    /* Injected by the browser to make sites read consistently.
       Conservative on purpose: nothing is hidden, nothing is repositioned, and each
       site keeps its own colours. */


    /* Typography. Containers only -- see the note in SiteStyle.swift about why this
       must never be a universal selector. */
    body, p, td, th, li, dd, dt, label, caption, figcaption, blockquote,
    h1, h2, h3, h4, h5, h6,
    input, button, select, textarea, optgroup, option {
      font-family: var(--x-font) !important;
    }
    code, pre, kbd, samp { font-family: var(--x-mono) !important; }

    /* Applied to running text only, never to `body`. Inherited into a row whose
       height the site fixed, a taller line box pushes a wrapped title straight over
       the row beneath it. */
    body { -webkit-font-smoothing: antialiased; }
    p, li, dd, blockquote { line-height: 1.5 !important; }

    h1, h2, h3, h4, h5, h6 { font-weight: 650 !important; }

    /* Links behave the same everywhere. The colour is left alone deliberately: it has
       to work against a background this stylesheet cannot see. */
    a { text-decoration: none !important; }
    a:hover { text-decoration: underline !important; }

    /* Listings are the substance of these sites and the biggest visual difference
       between them. Width and layout are untouched so column sizing still works. */
    table { border-collapse: collapse !important; }
    /* VERTICAL padding only. Horizontal padding is frequently load-bearing: a listing
       row draws its category icon in the cell's left inset, and replacing that inset
       drops the title straight on top of the icon. Row rhythm is uniform; the space a
       site reserved for its own artwork is left exactly as it was. */
    th, td {
      padding-top: 7px !important;
      padding-bottom: 7px !important;
      vertical-align: middle !important;
      border-bottom: 1px solid var(--x-rule) !important;
    }
    th {
      text-align: left !important;
      font-weight: 600 !important;
      letter-spacing: 0.02em;
    }
    tbody tr:nth-child(even) { background-color: var(--x-zebra) !important; }
    tbody tr:hover { background-color: var(--x-hover) !important; }

    /* Controls */
    /* Radius and border only. Padding is deliberately NOT forced: a search field
       commonly carries a large padding-left to clear a magnifier icon positioned over
       it, and replacing that padding drops the icon straight on top of the text. */
    input, select, textarea, button {
      border-radius: var(--x-radius) !important;
      border: 1px solid var(--x-rule) !important;
    }
    /* Anything the site rounded gets the theme's corner instead; see
       normaliseSurfaces(), which only touches elements that already have a radius. */
    button, input[type="submit"], input[type="button"], input[type="reset"] {
      cursor: pointer !important;
    }
    /* Checkboxes and radios are sized by the UA; padding would deform them. */
    input[type="checkbox"], input[type="radio"] {
      padding: 0 !important;
      border: none !important;
    }

    /* --------------------------------------------------------------- theme ---- */
    /* An imposed palette, not an inversion. Inverting gives every site a DIFFERENT
       palette -- its own colours, flipped -- and leaves an already-dark site glaring.
       Painting one scheme gives every site the SAME palette, which is the point.
       It also means no `filter` on <html>, so `position: fixed` keeps working. */

    /* EVERY element, not a list of containers. Anything a site paints is replaced.
       The exclusions below are per-PROPERTY, never per-element: an icon still gets the
       new colour and spacing, it just keeps the one declaration that makes it an icon. */
    /* The `:not(#\9)` chain is a specificity device, not a filter -- `#\9` is an
       escaped id that cannot exist, so this still matches every element, but each
       clause adds id-level specificity.
       Without it these rules carry ZERO specificity, and `!important` only wins
       against other `!important` by being more specific. Any site rule like
       `.torrent-list td { color: #333 !important }` would beat a bare `*`, which is
       exactly how elements slip through an override that looks universal. */
    *:not(#\9):not(#\9):not(#\9):not(#\9) {
      background-color: transparent !important;
      border-color: var(--x-border) !important;
      box-shadow: none !important;
      text-shadow: none !important;
    }

    /* A background image is DECORATION on something that has content of its own, and
       is the CONTENT itself on something that does not -- sprite icons, flags, quality
       badges, rating stars. The first kind goes; the second kind stays, or the page
       loses information rather than just colour. Pseudo-elements are left alone
       entirely, since ::before is where sites most often hide an icon. */
    *:not(#\9):not(#\9):not(#\9):not(#\9):not(:empty):not(i):not([class*="icon"]):not([class*="ico-"]):not([class*="flag"]):not([class*="sprite"]):not([class*="badge"]):not([class*="star"]) {
      background-image: none !important;
    }

    :root:not(#\9):not(#\9):not(#\9):not(#\9), html:not(#\9):not(#\9):not(#\9):not(#\9), body:not(#\9):not(#\9):not(#\9):not(#\9) {
      background: var(--x-bg) !important;
    }

    /* One text colour everywhere. Links are the deliberate exception.
       `html, body` are listed explicitly because a descendant selector never matches
       the element it descends from: `body :not(a)` would leave body's own colour in
       place, and everything inheriting from it would keep the site's. */
    html:not(#\9):not(#\9):not(#\9):not(#\9), body:not(#\9):not(#\9):not(#\9):not(#\9), *:not(#\9):not(#\9):not(#\9):not(#\9):not(a):not(a *) {
      color: var(--x-fg) !important;
    }
    a:not(#\9):not(#\9):not(#\9):not(#\9), a:not(#\9):not(#\9):not(#\9):not(#\9) * { color: var(--x-link) !important; }
    a:not(#\9):not(#\9):not(#\9):not(#\9):hover, a:not(#\9):not(#\9):not(#\9):not(#\9):hover * { color: var(--x-link-hover) !important; }

    /* Pseudo-elements carry a site's accent more often than anything else: a list
       marker is usually `::before { content: "\BB"; color: <brand> }`. They were
       exempt from everything above, which is why one colour kept surviving.
       Colour and background-colour are safe to impose. `border-color` is NOT, and is
       handled in script instead -- a CSS triangle is four borders with three of them
       transparent, so setting all four fills it into a square. */
    *:not(#\9):not(#\9):not(#\9):not(#\9)::before, *:not(#\9):not(#\9):not(#\9):not(#\9)::after {
      color: var(--x-fg) !important;
      background-color: transparent !important;
    }
    a:not(#\9):not(#\9):not(#\9):not(#\9)::before, a:not(#\9):not(#\9):not(#\9):not(#\9)::after { color: var(--x-link) !important; }

    /* The wordmark the script swaps in for a logo image. */
    .x-wordmark {
      display: inline-flex !important;
      align-items: center !important;
      justify-content: flex-start !important;
      font-family: var(--x-font) !important;
      font-weight: 700 !important;
      letter-spacing: -0.02em !important;
      line-height: 1 !important;
      white-space: nowrap !important;
      color: var(--x-fg) !important;
      background: none !important;
      /* It stands in for an image, so it must not spill out of the image's box. */
      overflow: hidden !important;
      max-width: 100% !important;
      vertical-align: middle !important;
    }
    a .x-wordmark, a:hover .x-wordmark { color: var(--x-link) !important; }

    /* Listings: a raised surface with real separation. */
    table:not(#\9):not(#\9):not(#\9):not(#\9) { background-color: var(--x-surface) !important; }
    th:not(#\9):not(#\9):not(#\9):not(#\9) {
      background-color: var(--x-surface-2) !important;
      border-bottom: 1px solid var(--x-border) !important;
    }
    td:not(#\9):not(#\9):not(#\9):not(#\9) { border-bottom: 1px solid var(--x-border) !important; }
    tbody tr:not(#\9):not(#\9):not(#\9):not(#\9):nth-child(even) { background-color: var(--x-zebra) !important; }
    tbody tr:not(#\9):not(#\9):not(#\9):not(#\9):hover { background-color: var(--x-hover) !important; }

    /* Changing the typeface changes how much room text needs, and a fixed-width
       control with padding added on top grows past its slot and pushes into whatever
       sits beside it. border-box keeps the outer size exactly as the site sized it. */
    input, select, textarea, button { box-sizing: border-box !important; }

    /* A release name has no break opportunity -- "Show.S04E04.1080p.x265-ELiTE" is one
       unbroken token to the line breaker, since a full stop is not a break point. Set
       in a wider typeface it pushes its cell past the viewport and the whole PAGE
       scrolls sideways.
       This was removed once, to stop wrapped titles colliding with the row beneath.
       That collision was caused by the forced `line-height`, not by wrapping: with the
       line-height gone rows grow to fit, so wrapping is safe and the horizontal
       overflow is not. */
    td, th, li, p, dd, figcaption, blockquote { overflow-wrap: break-word !important; }

    /* And a table may not push the page wider than the window regardless. */
    table { max-width: 100% !important; }

    /* Controls read as controls. */
    input:not(#\9):not(#\9):not(#\9):not(#\9), select:not(#\9):not(#\9):not(#\9):not(#\9), textarea:not(#\9):not(#\9):not(#\9):not(#\9), button:not(#\9):not(#\9):not(#\9):not(#\9) {
      background-color: var(--x-surface-2) !important;
      color: var(--x-fg) !important;
      border: 1px solid var(--x-border) !important;
    }
    button, input[type="submit"], input[type="button"], input[type="reset"] {
      background-color: var(--x-raised) !important;
    }
    ::placeholder { color: var(--x-muted) !important; }

    /* Artwork is left completely alone -- no filter anywhere, so posters, logos and
       screenshots render exactly as published. */
    img, video, canvas, picture { background-color: transparent !important; }

    hr, td, th { border-color: var(--x-border) !important; }

    /* ------------------------------------------------------ per-site escape ---- */
    /* The script stamps the hostname on <html>, so a site this does not suit can be
       excepted without turning the whole thing off. Uncomment and edit:

    html[data-x-host="example.com"],
    html[data-x-host="example.com"] body,
    html[data-x-host="example.com"] body :not(a):not(a *) {
      background-color: revert !important;
      background-image: revert !important;
      color: revert !important;
    }
    */
    """#

    /// Wrapped so a page that rebuilds its own `<head>` during boot does not drop the
    /// stylesheet, and so injecting twice is harmless.
    static func userScript(css: String) -> WKUserScript? {
        let text = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Carried as JSON so quotes, newlines and backslashes in the CSS cannot break
        // out of the script.
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let literal = String(data: data, encoding: .utf8)
        else { return nil }

        let source = """
        (function () {
          var css = \(literal)[0];
          var root = document.documentElement;

          // "1337x.to" -> "1337x";  "annas-archive.pk" -> "Annas Archive".
          function siteName() {
            var h = location.hostname;
            if (h.indexOf('www.') === 0) h = h.slice(4);
            var parts = h.split('.')[0].split('-');
            var out = [];
            for (var i = 0; i < parts.length; i++) {
              if (!parts[i]) continue;
              out.push(parts[i].charAt(0).toUpperCase() + parts[i].slice(1));
            }
            return out.join(' ') || h;
          }

          function norm(s) {
            var o = '', t = String(s || '').toLowerCase();
            for (var i = 0; i < t.length; i++) {
              var c = t.charAt(i);
              if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) o += c;
            }
            return o;
          }

          function siteKey() { return norm(location.hostname.replace('www.', '').split('.')[0]); }

          // Does this text name the site? Compared both ways because the file is often
          // shorter than the host ("audiobook.png" on theaudiobookbay.se) and sometimes
          // longer ("LimeTorrents Home" on limetorrents.fun).
          function namesSite(text) {
            var t = norm(text), k = siteKey();
            if (t.length < 4 || k.length < 4) return false;
            return t.indexOf(k) >= 0 || k.indexOf(t) >= 0;
          }

          // Filename without directories or extension: the full src is no good, since a
          // book cover served from the site's own CDN carries the hostname too.
          function fileStem(src) {
            var s = String(src || '').split('?')[0].split('#')[0];
            var last = s.substring(s.lastIndexOf('/') + 1);
            var dot = last.lastIndexOf('.');
            return dot > 0 ? last.substring(0, dot) : last;
          }

          function looksLikeLogo(el) {
            var s = ((el.className || '') + ' ' + (el.id || '') + ' ' +
                     (el.getAttribute('alt') || '')).toLowerCase();
            if (s.indexOf('logo') >= 0 || s.indexOf('brand') >= 0 ||
                s.indexOf('wordmark') >= 0) return true;
            if (namesSite(fileStem(el.getAttribute('src')))) return true;
            if (namesSite(el.getAttribute('alt'))) return true;
            return false;
          }

          function wordmark(width, height) {
            var span = document.createElement('span');
            span.className = 'x-wordmark';
            span.textContent = siteName();
            // The replacement takes the image's EXACT box. Anything else reflows the
            // masthead, which is where overlap comes from.
            span.style.width = width + 'px';
            span.style.height = height + 'px';
            span.style.fontSize = Math.max(10, Math.round(height * 0.62)) + 'px';
            return span;
          }

          // Scale the text until it spans the image's width. Done by measurement
          // because CSS cannot size type to fit a box, and iteratively because the
          // relationship between font-size and rendered width is not exactly linear
          // once kerning and hinting are involved.
          // An inline parent does not contain a fixed-height inline-flex child: the
          // child overhangs the line box, so it can sit on top of whatever is above or
          // below. Shrink-wrapping the parent makes the replacement occupy exactly the
          // space the image did.
          function containIn(parent) {
            if (!parent || parent.getAttribute('data-x-contain')) return;
            var d = getComputedStyle(parent).display;
            if (d === 'inline') {
              parent.style.display = 'inline-flex';
              parent.style.alignItems = 'center';
              parent.setAttribute('data-x-contain', '1');
            }
          }

          function fitToWidth(span, width, height) {
            var size = parseFloat(span.style.fontSize) || 16;
            for (var pass = 0; pass < 4; pass++) {
              span.style.width = 'auto';
              var natural = span.getBoundingClientRect().width;
              span.style.width = width + 'px';
              if (!natural || !width) break;
              var next = size * (width / natural);
              // Never taller than the image it replaced: a short name would otherwise
              // scale up until it collided with whatever sits above and below.
              next = Math.min(next, height * 0.82);
              next = Math.max(9, Math.min(next, 160));
              if (Math.abs(next - size) < 0.4) { size = next; break; }
              size = next;
              span.style.fontSize = size + 'px';
            }
            span.style.fontSize = size.toFixed(1) + 'px';
          }

          // A site's logo is the one thing a stylesheet cannot make uniform -- it is
          // artwork. Replacing it with the site's name, set at the same height, is what
          // makes different sites actually look like one app. The surrounding <a> is
          // left in place, so clicking the logo still goes home.
          function swapLogos() {
            var imgs = document.images, swapped = 0;
            for (var i = 0; i < imgs.length && swapped < 3; i++) {
              var img = imgs[i];
              if (!img || img.getAttribute('data-x-logo')) continue;

              var isLogo = looksLikeLogo(img);
              if (!isLogo && img.closest) {
                // Otherwise: an image near the top that is a link to the site root.
                var a = img.closest('a');
                if (a) {
                  var href = a.getAttribute('href') || '';
                  var atTop = img.getBoundingClientRect().top + (window.scrollY || 0) < 260;
                  if (atTop && (href === '/' || href === './' ||
                                href === location.origin + '/')) isLogo = true;
                }
              }
              if (!isLogo) continue;

              var h = Math.round(img.getBoundingClientRect().height) || img.height || 0;
              var wNow = Math.round(img.getBoundingClientRect().width) || img.width || 0;
              if (h < 18 || wNow < 40) continue;  // not laid out yet, or too small
              if (img.getBoundingClientRect().top + (window.scrollY || 0) > 400) continue;
              var w = Math.round(img.getBoundingClientRect().width) || img.width || 0;
              img.setAttribute('data-x-logo', '1');
              img.style.display = 'none';
              if (img.parentNode) {
                var mark = wordmark(w, h);
                img.parentNode.insertBefore(mark, img);
                containIn(mark.parentElement);
                // Must be in the document before it can be measured.
                fitToWidth(mark, w, h);
              }
              swapped++;
            }

            // Logos drawn as a CSS background on an empty element.
            var els = document.querySelectorAll('[class*="logo" i], [id*="logo" i]');
            for (var j = 0; j < els.length; j++) {
              var el = els[j];
              if (el.getAttribute('data-x-logo')) continue;
              if (el.querySelector('img')) continue;
              if ((el.textContent || '').trim().length) continue;
              if (getComputedStyle(el).backgroundImage === 'none') continue;
              var box = el.getBoundingClientRect();
              var eh = Math.round(box.height), ew = Math.round(box.width);
              if (eh < 14) continue;
              el.setAttribute('data-x-logo', '1');
              el.style.backgroundImage = 'none';
              var m = wordmark(ew, eh);
              el.appendChild(m);
              containIn(el);
              fitToWidth(m, ew, eh);
            }
          }

          // Corners, and the one place a transparent background is wrong.
          //
          // Stripping every background to transparent is right for layout containers
          // and WRONG for an overlay: a dropdown, autocomplete panel or menu is drawn
          // on top of the page, so with no background of its own the page shows
          // straight through it and the text becomes unreadable. Those are identified
          // by being positioned and actually containing something.
          //
          // Corners are normalised here rather than in CSS because only elements that
          // ALREADY have a radius should get the theme's -- rounding everything would
          // round table cells and page containers too.
          function normaliseSurfaces() {
            var nodes = document.querySelectorAll('*:not([data-x-surf])');
            var cap = Math.min(nodes.length, 4000);
            var pageL = pageLuminance();
            for (var i = 0; i < cap; i++) {
              try { normaliseOne(nodes[i], i, pageL); } catch (e) {}
            }
          }

          // Luminance of the theme's page colour, so every judgement below is relative
          // to the palette in force rather than to an assumption about it.
          function pageLuminance() {
            try {
              var c = getComputedStyle(document.body || root).backgroundColor;
              var n = [], b = '';
              for (var i = 0; i < c.length; i++) {
                var ch = c.charAt(i);
                if ((ch >= '0' && ch <= '9') || ch === '.') b += ch;
                else if (b) { n.push(parseFloat(b)); b = ''; }
              }
              if (b) n.push(parseFloat(b));
              if (n.length < 3) return 20;
              return 0.2126 * n[0] + 0.7152 * n[1] + 0.0722 * n[2];
            } catch (e) { return 20; }
          }

          function normaliseOne(el, i, pageL) {
            {
              el.setAttribute('data-x-surf', '1');
              var cs = getComputedStyle(el);
              var r = el.getBoundingClientRect();

              // Never touch something that is not visible.
              //
              // A leftover ad slot is commonly neutralised by making it invisible
              // rather than removing it -- zero size, `visibility:hidden`, `opacity:0`.
              // Painting a surface onto one of those, or giving its text our colour,
              // turns something deliberately hidden back into something you can see.
              // The content blocker's own hiding uses `display:none`, which never
              // reaches here at all, but the others would.
              if (!r.width || !r.height) return;
              if (cs.visibility === 'hidden' || cs.visibility === 'collapse') return;
              if (parseFloat(cs.opacity) === 0) return;

              // Final sweep: any surface still painted in the site's own colour.
              //
              // An author rule cannot beat an inline `!important`, however specific it
              // is, and that is how a site's own button colour survives everything in
              // the stylesheet. Setting it inline-important here is the only thing that
              // outranks it. Keyed on lightness rather than on a list of selectors, so
              // it closes every hole of this shape at once and not just the one seen.
              //
              // Measured against the PAGE, not a fixed number. A hard-coded "lighter
              // than 70 is theirs" holds only while every theme is dark; under a light
              // theme it inverts and overrides every surface including our own. The
              // test is: does this differ from the page background by a real margin,
              // in the direction away from it.
              var bgc = cs.backgroundColor;
              if (bgc && bgc !== 'transparent') {
                var cn = [], cbuf = '';
                for (var ci = 0; ci < bgc.length; ci++) {
                  var cch = bgc.charAt(ci);
                  if ((cch >= '0' && cch <= '9') || cch === '.') cbuf += cch;
                  else if (cbuf) { cn.push(parseFloat(cbuf)); cbuf = ''; }
                }
                if (cbuf) cn.push(parseFloat(cbuf));
                var opaque = cn.length >= 3 && !(cn.length >= 4 && cn[3] < 0.5);
                if (opaque) {
                  var L = 0.2126 * cn[0] + 0.7152 * cn[1] + 0.0722 * cn[2];
                  var offending = pageL < 128 ? (L > pageL + 45) : (L < pageL - 45);
                  if (offending) {
                    var t = el.tagName;
                    var control = t === 'INPUT' || t === 'BUTTON' || t === 'SELECT' ||
                                  t === 'TEXTAREA';
                    el.style.setProperty('background-color',
                      control ? 'var(--x-surface-2)' : 'var(--x-surface)', 'important');
                    el.style.setProperty('background-image', 'none', 'important');
                  }
                }
              }

              var radius = parseFloat(cs.borderTopLeftRadius) || 0;
              if (radius > 0) {
                // A pill or a circular avatar is a shape, not a corner treatment, and
                // squaring it off to 6px would be a disfigurement rather than a theme.
                var minSide = Math.min(r.width, r.height) || 0;
                var circular = minSide > 0 && radius >= minSide * 0.45;
                if (!circular) {
                  el.style.setProperty('border-radius', 'var(--x-radius)', 'important');
                }
              }

              var floating = cs.position === 'absolute' || cs.position === 'fixed';
              var vw = window.innerWidth || 1440, vh = window.innerHeight || 900;
              // An overlay is a PANEL: positioned, carrying text, and modest in size.
              // Requiring text is what separates a dropdown from a full-bleed decorative
              // container, which is also positioned and also has children -- painting one
              // of those turns a whole hero section into a flat slab.
              var isPanel = floating
                && (el.textContent || '').trim().length > 0
                && r.width > 110 && r.height > 34
                && r.width < vw * 0.85 && r.height < vh * 0.8;
              if (isPanel) {
                el.style.setProperty('background-color', 'var(--x-surface)', 'important');
                el.style.setProperty('backdrop-filter', 'none', 'important');
              }

              // Full-bleed background IMAGES, wherever they are hung.
              //
              // The stylesheet spares background images on empty elements, because on
              // an element with no content the background IS the content -- a sprite
              // icon, a flag. A photographic backdrop is usually hung on an empty div
              // too, so it slips through that exemption; and a pseudo-element can carry
              // one, which no CSS rule here reaches at all.
              //
              // Size settles it. An icon is tiny. A backdrop covers the page.
              var big = r.width > vw * 0.5 && r.height > vh * 0.3;
              if (big) {
                var ebg = cs.backgroundImage;
                if (ebg && ebg.indexOf('url(') >= 0) {
                  el.style.setProperty('background-image', 'none', 'important');
                }
                for (var pk = 0; pk < 2; pk++) {
                  var pName = pk ? '::after' : '::before';
                  var pcs = getComputedStyle(el, pName);
                  if (!pcs || !pcs.backgroundImage) continue;
                  if (pcs.backgroundImage.indexOf('url(') < 0) continue;
                  var sheet2 = document.getElementById('x-unified-style');
                  if (!sheet2 || !sheet2.sheet) continue;
                  // `i` is this loop's own counter. An earlier version used a variable
                  // belonging to a different function, which threw a ReferenceError and
                  // silently aborted the whole pass at the first element that reached
                  // here -- the outer try swallowed it.
                  var tag2 = el.getAttribute('data-x-edge');
                  if (!tag2) { tag2 = 'bg' + i; el.setAttribute('data-x-edge', tag2); }
                  try {
                    sheet2.sheet.insertRule('[data-x-edge="' + tag2 + '"]' + pName
                      + '{background-image:none !important;}',
                      sheet2.sheet.cssRules.length);
                  } catch (e4) {}
                }
              }

              // Full-bleed decorative artwork.
              //
              // Size is the test, not position: the backdrop that prompted this is a
              // STATIC inline <svg> spanning the whole hero. A poster or screenshot is
              // content and is nowhere near this big -- cover art runs ~300x450, well
              // under 60% of the viewport -- and content images carry text nowhere, so
              // requiring an empty subtree keeps captions and figures out of it.
              var tag = el.tagName.toLowerCase();
              var isArt = tag === 'img' || tag === 'svg' || tag === 'canvas' || tag === 'video';
              if (isArt && (el.textContent || '').trim().length === 0
                  && r.width > vw * 0.6 && r.height > vh * 0.4) {
                el.style.setProperty('display', 'none', 'important');
              }
            }
          }

          // A dropdown does not exist until it is opened, so a one-off pass never sees
          // it. This is what makes the overlay rule apply to the panel that appears
          // when a search box is focused.
          var pending = null;
          function watchForOverlays() {
            if (!window.MutationObserver || root.getAttribute('data-x-watch')) return;
            root.setAttribute('data-x-watch', '1');
            new MutationObserver(function () {
              if (pending) clearTimeout(pending);
              pending = setTimeout(function () {
                try { normaliseSurfaces(); } catch (e) {}
              }, 120);
            }).observe(root, { childList: true, subtree: true });
          }

          function apply() {
            // Plain CSS has no way to ask what site it is on, so the hostname is put
            // where a selector can reach it. This is what makes a per-site exception
            // possible from the editable stylesheet.
            try { root.setAttribute('data-x-host', location.hostname); } catch (e) {}
            if (!document.getElementById('x-unified-style')) {
              var el = document.createElement('style');
              el.id = 'x-unified-style';
              el.textContent = css;
              (document.head || root).appendChild(el);
            }
            // Equal specificity is settled by document order, and the site's own
            // stylesheets load after this one was injected. Moving it to the end of
            // <head> on each pass keeps it last.
            var existing = document.getElementById('x-unified-style');
            if (existing && existing.parentNode && existing.parentNode.lastChild !== existing) {
              existing.parentNode.appendChild(existing);
            }
            // The page canvas, enforced from script rather than the sheet.
            //
            // At least one site keeps its own <html> background against a rule carrying
            // four ids of specificity and !important, and the canvas is the one surface
            // where losing shows: it is what fills the overscroll area and anywhere the
            // body does not reach. An inline declaration marked important outranks any
            // author rule, so this settles it whatever the site does. The value is read
            // back from the sheet, so an edited palette still applies.
            try {
              var bg = getComputedStyle(root).getPropertyValue('--x-bg');
              if (bg && bg.trim()) {
                root.style.setProperty('background-color', bg.trim(), 'important');
                if (document.body) {
                  document.body.style.setProperty('background-color', bg.trim(), 'important');
                }
              }
            } catch (e) {}

            // Gradients are decoration, never content.
            //
            // The stylesheet spares background images on empty elements, because on an
            // element with no content of its own the background IS the content -- a
            // sprite icon, a flag. That rule also spares decorative gradient overlays,
            // which are usually on empty elements too, and those are exactly what
            // should go. CSS cannot test the VALUE of a property, so the distinction is
            // drawn here: a gradient has no `url(`, and nothing meaningful is ever
            // drawn as a bare gradient.
            try {
              var nodes = document.querySelectorAll('*');
              var limit = Math.min(nodes.length, 6000);
              for (var n = 0; n < limit; n++) {
                var node = nodes[n];
                if (node.getAttribute('data-x-degrad')) continue;
                var bi = getComputedStyle(node).backgroundImage;
                if (bi && bi !== 'none' && bi.indexOf('url(') === -1) {
                  node.style.setProperty('background-image', 'none', 'important');
                  node.setAttribute('data-x-degrad', '1');
                }
              }
            } catch (e) {}

            // Coloured pseudo-element borders: shapes, not boxes.
            //
            // A triangle is `border: 8px solid transparent` with one side given a
            // colour, so a blanket border-color rule turns it into a filled square.
            // Only the sides that are actually painted get recoloured, which keeps the
            // shape and drops the accent. Bounded, and run once per element.
            try {
              var sheet = document.getElementById('x-unified-style');
              var rules = sheet && sheet.sheet;
              if (rules) {
                var seen = 0, all2 = document.querySelectorAll('*');
                var cap = Math.min(all2.length, 3000);
                var sides = ['Top', 'Right', 'Bottom', 'Left'];
                for (var q = 0; q < cap; q++) {
                  var e2 = all2[q];
                  if (e2.getAttribute('data-x-edge')) continue;
                  for (var pi = 0; pi < 2; pi++) {
                    var pseudo = pi ? '::after' : '::before';
                    var ps = getComputedStyle(e2, pseudo);
                    if (!ps || ps.content === 'none' || ps.content === 'normal') continue;
                    var painted = [];
                    for (var si = 0; si < 4; si++) {
                      var col = ps['border' + sides[si] + 'Color'];
                      var wid = parseFloat(ps['border' + sides[si] + 'Width']) || 0;
                      if (wid > 0 && col && col.indexOf('rgba(') !== 0) painted.push(sides[si]);
                    }
                    if (!painted.length) continue;
                    seen++;
                    e2.setAttribute('data-x-edge', String(seen));
                    var decl = '';
                    for (var pj = 0; pj < painted.length; pj++) {
                      decl += 'border-' + painted[pj].toLowerCase()
                            + '-color: var(--x-fg) !important;';
                    }
                    try {
                      rules.insertRule('[data-x-edge="' + seen + '"]' + pseudo
                                       + '{' + decl + '}', rules.cssRules.length);
                    } catch (e3) {}
                  }
                }
              }
            } catch (e) {}

            try { normaliseSurfaces(); } catch (e) {}
            try { swapLogos(); } catch (e) {}
          }

          apply();
          document.addEventListener('DOMContentLoaded', function () { apply(); watchForOverlays(); });
          // Some sites replace <head> late in boot.
          window.addEventListener('load', apply);
        })();
        """
        // Every frame, not just the main one.
        //
        // Sites embed real UI in iframes -- LimeTorrents' entire search box is one --
        // and a main-frame-only injection leaves that content wearing the site's own
        // colours in the middle of an otherwise themed page. Each frame styles itself:
        // the script runs in that frame's context, so it reads that frame's document
        // and stamps that frame's hostname.
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }
}
