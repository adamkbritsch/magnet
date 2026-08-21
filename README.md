<p align="center">
  <img src="assets/app-icon.png" alt="Magnet" width="128">
</p>

<h1 align="center">Magnet</h1>

**A browser shaped for the sites it is pointed at.**

Torrent sites are a browser's worst case. They are hostile to look at, they move
domain without warning, they are wrapped in advertising that a general-purpose
browser only partly removes, and they hand you a magnet link that then has to
find its way to a torrent client somewhere else entirely. A normal browser treats
all of that as your problem.

Magnet treats it as the application's problem. Every site is repainted in one
theme, a site that stops answering is looked up under its other domains, a magnet
goes straight to your client without a round trip through another app, and a
direct download is filed where you keep things rather than into `~/Downloads`.

It ships with **nothing configured** — no sites, no home page, no services. All of
it is set up in Settings.

## Why

The obvious answer is a normal browser with an ad blocker, and for most of the web
that is the right answer. It falls down here in three specific places.

**A blocker cannot reach a self-hosted ad.** Filter lists block advertising
*networks*, by hostname. A tracker's own affiliate banner is served from the
tracker's own domain, so no list contains it and no amount of updating will.

**A bookmark is a fixed address, and these addresses are not fixed.** Domains get
seized and rotated. A bookmark bar full of dead links is the normal end state, and
fixing it by hand means finding a current mirror list first.

**A magnet link is a handoff to a program that is somewhere else.** Usually a
client on a seedbox or a NAS, behind a network that may not welcome the connection.
The browser's job ends at "open in application", which is the wrong end.

None of these is hard on its own. They are just tedious forever, and an application
that knows what kind of site it is looking at can do all three quietly.

### Prior art

**Any browser plus [uBlock Origin](https://github.com/gorhill/uBlock)** is more
capable at blocking than this is, and it is not close. uBO runs scriptlets and
procedural filters that WebKit's content blockers have no equivalent for. If
blocking is all you want, use a browser that can run it.

What a browser extension cannot do is the rest: it does not know which domains are
alternates of each other, it cannot post a magnet to a client on your behalf, and
it cannot decide where a downloaded file belongs. Magnet converts uBO's own filter
lists into WebKit's native content blocker — around 141,000 rules — and accepts the
loss of the dynamic parts in exchange for doing the other three.

**[PWAsForFirefox](https://github.com/filips123/PWAsForFirefox)** gives a site its
own window, which is most of what a site-specific browser is. This replaced one.
The difference is that a wrapper is still just a window: it has no opinion about
mirrors, magnets, downloads or appearance.

## How it fits together

```
   macOS app  ──optional──▶  CONNECT proxy  ──▶  the site
    Magnet                   (yours, anywhere)
      │
      ├──magnet link──▶  qBittorrent Web API   (client, wherever it lives)
      │
      └──direct file──▶  this Mac  ──when whole──▶  SMB share
```

- **`macapp/`** — SwiftUI, built with plain `swiftc`. No Xcode project.
- **`tools/`** — the filter-list converter, test suites, and fixtures.
- **`nas/`** — a tinyproxy container, if you want the forward proxy.

## Install

**1. Clone it and set up the build.** Copy `local.env.example` to `local.env` and
fill in a bundle id of your own. That id is also where your settings are stored and
how macOS matches your permissions, so pick one and keep it.

```bash
cp local.env.example local.env
./macapp/build.sh --install
```

The first build converts uBlock Origin's filter lists, which takes a few minutes
and needs network. Later builds reuse the cache. If it fails, the app still runs —
without content blocking.

**2. Open it once from Finder.** The app is signed with a certificate it creates
itself, not one Apple issued, so Gatekeeper will want a right-click and Open the
first time.

**3. Set a home site.** Settings opens on the **Sites** tab. At minimum, give it a
site to open. Everything else is optional and can be filled in later:

| Tab | For |
|---|---|
| **Sites** | The home site, the sites in the bar, and a Firefox bookmark folder to mirror |
| **Connection** | Direct, or through a forward proxy of your own |
| **Torrent Client** | A qBittorrent Web API endpoint for magnet links |
| **Downloads** | An SMB share to file direct downloads into |
| **Mirrors** | Fallback domains for sites that move |
| **Appearance** | Five themes, or your own stylesheet |
| **Blocking** | Filter list status |

**4. Choose "Always Allow" if macOS asks about the Keychain.** "Allow" is one-shot
and asks again forever.

## Requirements

- macOS 14 or later. Building needs Xcode's command line tools; the icon step also
  wants Xcode itself, and is skipped without it.
- Python 3, for the filter-list converter.
- Everything else is optional. No proxy, no torrent client and no NAS is a
  perfectly valid setup — those features simply stay dormant.

## What it does

### The bar is grouped by what a site is for

Sites come from a Firefox bookmark folder, from sites you add by hand, or both, and
are grouped into **Everything**, **Movies & TV**, **Games** and **Books**. Drag a
chip to move it. Click a section icon to fold it away.

Classification is a small explicit table rather than something derived, because the
obvious source is wrong often enough to notice: FMHY lists most sites in several
sections, and the first mention is routinely not the site's purpose.

### A site that stops answering is looked up elsewhere

When a navigation fails at the transport layer, the app probes the site's other
domains, switches to one that answers, and remembers it — re-checking later so it
returns home when the site recovers. Right-click any chip to pick a domain by hand.

Domain lists come from mirror sets you define. A set can name a **Wikipedia
article**, in which case the list is re-read from that article's infobox — which is
how a site that rotates domains under takedown keeps working without an update.
Optionally, FMHY's published list adds mirrors for hundreds of sites in bulk.

**Only transport failures count.** An HTTP-level rejection — a Cloudflare challenge
above all — proves the domain is alive, so it never triggers a switch.

### It remembers which route works on which network

A network that blocks trackers costs you the direct probe's timeout on every launch,
having already learned the answer the launch before. Magnet records which route worked
and tries that one first next time — so on a network where the NAS is the only way
through, the wait is gone.

It is remembered, not trusted: the other route still follows, so a network that
changes its mind costs one wasted probe and then corrects itself. Pinning a route by
hand records it too, since choosing one says more than any probe does.

Networks are keyed by the **router's MAC address**, not the Wi-Fi name. macOS will not
give up the SSID — CoreWLAN, `networksetup`, `ipconfig getsummary` and
`system_profiler` all answer `<redacted>` without Location Services authorization, and
a convenience feature is not worth a location prompt. The router identifies the
network just as well, and where the DHCP lease carries a domain name, that becomes the
label you see in Settings.

### Why a forward proxy, and not a reverse one

If you route the browser through a proxy to reach a Cloudflare-protected site, it
**must** be a forward (HTTP `CONNECT`) proxy. Measured:

| Path | Result |
|---|---|
| `curl`, direct | 403 challenge |
| `WKWebView`, direct | solved in ~6s |
| `WKWebView` through a Caddy **reverse** proxy | never solved, stuck 30s+ |
| `WKWebView` through an HTTP **CONNECT** proxy | solved in ~6s, same as direct |

A reverse proxy terminates TLS and rewrites the origin, so the challenge cannot
validate. `CONNECT` tunnels raw TLS to the origin, and Cloudflare sees an ordinary
browser. A corollary worth knowing: Cloudflare Tunnel carries HTTP services but not
CONNECT proxies, so remote access to such a proxy needs a VPN or tailnet.

### Magnets go straight to the client

Magnet and `.torrent` links are posted to a qBittorrent Web API rather than handed
to another application. Point it at a reverse proxy in front of the client rather
than the client's own port, and it works on networks that block that port.

### Adding a site adds its search plugin

qBittorrent can search sites itself, but only through a plugin per site, installed by
hand from a wiki of community links. Magnet keeps the two in step: add a site to the
bar and the plugin for it is installed into the client, on launch and whenever the bar
changes.

Only a built-in list of addresses is ever fetched — never one a page suggested — and
plugins are never removed, because hiding a chip for an afternoon is a reversible
action and uninstalling is not. Sites with no published plugin are named rather than
passed over, so "nothing to do" cannot be mistaken for "everything is searchable".

Where qBittorrent ships its own plugin for a site, that is the one installed. A
community fork under the same engine name does not sit alongside the official one, it
replaces it — and installing one is how you silently downgrade a working plugin. Where
a site has two plugins in circulation under *different* names, a client that already
has the other one is left alone, because two plugins for one site is not an error the
client reports: it just returns everything twice.

A plugin URL that has rotted fails silently: the client accepts the request, fetches
nothing, and ends up without the plugin. `tools/tests/run.sh --live` fetches every
address in the catalogue and checks it is still a working plugin.

### Downloads are filed, not dumped

Any site in the bar is a download source, so bookmarking one is all it takes. Files
land on this Mac first and move to the share once whole — a download writes
incrementally, and doing that over SMB is slow and leaves half-written files when
the link drops.

Where the file came FROM decides whether it is taken at all, which is a different
question from where it is filed. A decoy download button among the real ones serves
its payload from the advert's own host, so an executable offered by a host with
nothing to do with the site being read is refused outright — while an installer from
a repack site you bookmarked, which is the point of those sites, still works. So is a
download that starts without a click. Magnet links are checked for an actual info hash
before anything reaches the torrent client, since the scheme is trivial to forge and a
torrent client is a poor place to discover a link was an advert.

Where a file goes is decided by **what the site is**, using the same categories that
group the bar. Point the archive root at a folder nothing else manages: if it is
somewhere a media pipeline watches, captured files get imported and renamed out from
under you.

### Every site wears the same theme

Five themes — Slate, Midnight, Carbon, Forest and Paper (light) — plus your own
stylesheet, which is editable in Settings.

The restyling is uniform but not careless. It never overrides an inset a site
reserves for its own artwork: a search field's `padding-left` clears a magnifier
icon, and a listing cell's clears its category icon, so replacing either drops the
icon onto the text. Icon fonts survive because the typeface is set on containers
only, never on `*` — a declared value beats an inherited one, so a `*` selector
turns every icon on the page into a stray letter. A site's logo is replaced with its
name, set to the width the image occupied.

### Blocking

uBlock Origin's own lists, converted to WebKit's native content blocker. Three
things that cost a debugging cycle each:

- **WebKit's regex is a PCRE subset, and one bad rule fails the whole list.** No
  `\w` or `\d`, no `{n,m}`, no `(a|b)`, ASCII only.
- **`ignore-previous-rules` only cancels within the same compiled list**, so every
  block chunk must carry the full exception set or sites silently over-block.
- uBO's cosmetic filters must be stripped before the network parser sees them.

Self-hosted banners are handled separately, by shape and destination: an image at
least 300px wide with an aspect ratio of 3 or more, pointing off-domain. Both
conditions are required, which is what keeps a poster and a site's own announcement
visible.

### The "blank listings" symptom

During Cloudflare's ~6s check, a site serves its own shell with zero rows, which
looks like the blocker broke it. It has not: measured with filters on and off after
settling, the results are identical. The app covers the view with a "clearing the
check" state, capped at 15s so a stalled challenge still becomes clickable.

Diagnose anything in this class by A/B-ing rule lists **and waiting for render** —
an early probe lies.

### One thing it deliberately does not do

**It never opens anything in another browser.** A link asking for a new window is
dropped rather than handed off, because on these sites that request is almost always
the advertising rather than the content. The exception is narrow and deliberate: a
download link from a page you are already on loads in the same window, so nothing new
is opened and the file still arrives.

## Safety

- **Do not expose the forward proxy to the internet.** It will fetch anything, for
  anyone who can reach it. A tailnet or LAN only.
- **Point the archive root at a folder nothing else manages.** An import folder
  watched by a media pipeline will pick captured files up, rename them and move them.
- **Cleartext HTTP needs an App Transport Security exception**, listed in
  `local.env`. Without one the request fails before it leaves the process.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with any of the sites this can be pointed at, nor with uBlock Origin,
qBittorrent, or FMHY.

---

<p align="center">
  <img src="assets/app-icon.png" alt="The Magnet app icon" width="96">
</p>
