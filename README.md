<p align="center">
  <img src="assets/app-icon.png" alt="Magnet" width="128">
</p>

<h1 align="center">Magnet</h1>

**A browser shaped for the sites it is pointed at.**

Torrent sites are a browser's worst case. They move domain without warning, they are
wrapped in advertising that a general-purpose browser only partly removes, they start
downloads you did not ask for, and they hand you a magnet link that then has to find
its way to a torrent client somewhere else entirely. A normal browser treats all of
that as your problem.

Magnet treats it as the application's problem. Every request goes through a proxy you
control, a site that stops answering is looked up under its other domains, a magnet
goes straight to your client without a round trip through another app, a direct
download has to be approved before it can touch the disk, and adding a site to the bar
installs that site's search plugin into qBittorrent.

It ships with **nothing configured** — no sites, no home page, no services. All of it
is set up in Settings.

## Why

The obvious answer is a normal browser with an ad blocker, and for most of the web that
is the right answer. It falls down here in four specific places.

**A blocker cannot reach a self-hosted ad.** Filter lists block advertising *networks*,
by hostname. A tracker's own affiliate banner is served from the tracker's own domain,
so no list contains it and no amount of updating will.

**A bookmark is a fixed address, and these addresses are not fixed.** Domains get seized
and rotated. A bookmark bar full of dead links is the normal end state, and fixing it by
hand means finding a current mirror list first.

**A magnet link is a handoff to a program that is somewhere else.** Usually a client on
a seedbox or a NAS, behind a network that may not welcome the connection. The browser's
job ends at "open in application", which is the wrong end.

**A download here is guilty until proven innocent.** These pages start downloads from a
click on anything at all. A browser's job is to fetch what it is told to fetch; deciding
whether a file was actually wanted is outside its remit, and squarely inside this one's.

None of these is hard on its own. They are just tedious forever, and an application that
knows what kind of site it is looking at can do all four quietly.

### Prior art

**Any browser plus [uBlock Origin](https://github.com/gorhill/uBlock)** is more capable
at blocking than this is, and it is not close. uBO runs scriptlets and procedural
filters that WebKit's content blockers have no equivalent for. If blocking is all you
want, use a browser that can run it.

What a browser extension cannot do is the rest: it does not know which domains are
alternates of each other, it cannot post a magnet to a client on your behalf, it cannot
decide where a downloaded file belongs, and it cannot install search plugins into your
torrent client. Magnet converts uBO's own filter lists into WebKit's native content
blocker — about 137,000 rules — and accepts the loss of the dynamic parts in exchange
for doing the rest.

**[PWAsForFirefox](https://github.com/filips123/PWAsForFirefox)** gives a site its own
window, which is most of what a site-specific browser is. This replaced one. The
difference is that a wrapper is still just a window: it has no opinion about mirrors,
magnets, downloads or what a page is allowed to start.

## How it fits together

```
   macOS app  ──always──▶  CONNECT proxy  ──▶  the site
    Magnet                 (yours, anywhere)
      │
      ├──magnet link───▶  qBittorrent Web API   (client, wherever it lives)
      ├──search plugin─▶  qBittorrent Web API
      │
      ├──direct file───▶  this Mac  ──when whole──▶  SMB share
      │                   (after you approve it)
      │
      └──"Open in Browser"──▶  your default browser, directly, outside the tunnel
```

- **`macapp/`** — SwiftUI, built with plain `swiftc`. No Xcode project.
- **`tools/`** — the filter-list converter, test suites, and fixtures.
- **`nas/`** — a tinyproxy container for the forward proxy.

## Install

**1. Clone it and set up the build.** Copy `local.env.example` to `local.env` and fill
in a bundle id of your own. That id is also where your settings are stored and how macOS
matches your permissions, so pick one and keep it.

```bash
cp local.env.example local.env
./macapp/build.sh --install
```

The first build converts uBlock Origin's filter lists, which takes a few minutes and
needs network. Later builds reuse them, and refresh them once they are over a week old.
If conversion fails the app still runs, without content blocking.

`--install` replaces the copy in `~/Applications` and **restarts it if it is running**,
because a running process keeps the binary it started with — an installer that reports
"Installed" over a live process is lying by omission. It also removes its own build
output, so only one bundle carrying your id can ever be launched.

**2. Open it once from Finder.** The app is signed with a certificate it creates itself,
not one Apple issued, so Gatekeeper will want a right-click and Open the first time.

**3. Set up a proxy and a home site.** Both are required: there is no direct route.

| Tab | For |
|---|---|
| **Sites** | The home site, the sites in the bar, and a Firefox bookmark folder to mirror |
| **Connection** | The forward proxy every request goes through — **required** |
| **Torrent Client** | A qBittorrent Web API endpoint, for magnets and search plugins |
| **Downloads** | An SMB share to file approved downloads into, and hosts allowed to send them |
| **Mirrors** | Fallback domains for sites that move |
| **Appearance** | Page zoom |
| **Blocking** | Filter list status, count and age |

**4. Choose "Always Allow" if macOS asks about the Keychain.** "Allow" is one-shot and
asks again forever.

## Requirements

- macOS 14 or later. Building needs Xcode's command line tools; the icon step also wants
  Xcode itself, and is skipped without it.
- Python 3, for the filter-list converter.
- **A forward (`CONNECT`) proxy you can reach.** Not optional — see below.
- A torrent client and an SMB share are optional. Without them, magnets and download
  filing simply stay dormant.

## What it does

### Everything goes through the proxy

There is one route: a forward proxy of yours, typically on a NAS over a tailnet. The
direct connection was offered once and removed — reaching these sites straight from the
Mac is what an ordinary browser already does, so the app that only did that added
nothing. A tunnel that quietly stops being used on a network that happens to permit
direct traffic is worse than no tunnel, because it looks identical to one that works.

If the proxy does not answer, nothing loads and the app names the address that failed.
There is no fallback by design: that state is a problem to fix, and browsing around it
would hide the problem while silently dropping the tunnel.

It **must** be a forward (`CONNECT`) proxy, not a reverse one. Measured:

| Path | Result |
|---|---|
| `curl`, direct | 403 challenge |
| `WKWebView`, direct | solved in ~6s |
| `WKWebView` through a Caddy **reverse** proxy | never solved, stuck 30s+ |
| `WKWebView` through an HTTP **CONNECT** proxy | solved in ~6s, same as direct |

A reverse proxy terminates TLS and rewrites the origin, so a Cloudflare challenge cannot
validate. `CONNECT` tunnels raw TLS to the origin and Cloudflare sees an ordinary
browser. A corollary worth knowing: Cloudflare Tunnel carries HTTP services but not
CONNECT proxies, so remote access to such a proxy needs a VPN or tailnet.

### Open in Browser

Next to the route indicator. It hands the current page to your default browser, reached
directly, outside the tunnel — the deliberate way out for anything this app will not do:
a sign-in, a payment page, a download it refuses. When the proxy is down it opens the
home site instead, since that is exactly when it is the only control on screen that
still works.

This is the one handoff, and it is yours. The app never hands anything off on its own.

### The bar is grouped by what a site is for

Sites come from a Firefox bookmark folder, from sites you add by hand, or both, and are
grouped into **Everything**, **Movies & TV**, **Games** and **Books**. Drag a chip to
move it. Click a section icon to fold it away.

Classification is a small explicit table rather than something derived, because the
obvious source is wrong often enough to notice: FMHY lists most sites in several
sections, and the first mention is routinely not the site's purpose.

### A site that stops answering is looked up elsewhere

When a navigation fails at the transport layer, the app probes the site's other domains,
switches to one that answers, and remembers it — re-checking later so it returns home
when the site recovers. Right-click any chip to pick a domain by hand.

Domain lists come from mirror sets you define. A set can name a **Wikipedia article**, in
which case the list is re-read from that article's infobox — which is how a site that
rotates domains under takedown keeps working without an update. Optionally, FMHY's
published list adds mirrors for hundreds of sites in bulk.

**Only transport failures count.** An HTTP-level rejection — a Cloudflare challenge above
all — proves the domain is alive, so it never triggers a switch.

**And every probe goes through the proxy**, because that is the only way the app reaches
anything. This was wrong for a while and the symptom was specific: the home domain is
chosen at launch by probing it, that probe ran before any route existed, so it went out
directly — on a network where direct is exactly what does not work. The app rejected its
own home domain, opened a mirror, and the domain it had just declared dead loaded fine
through the proxy the moment you picked it by hand. The proxy is now built from settings
rather than handed down, so there is no longer an ordering to get wrong, and
`tools/tests/run.sh` fails if a site probe is ever written with a bare `URLSession`.

### Magnets go straight to the client

Magnet and `.torrent` links are posted to a qBittorrent Web API rather than handed to
another application. Point it at a reverse proxy in front of the client rather than the
client's own port, and it works on networks that block that port.

A magnet needs an actual info hash, a real click on a link to **that** torrent, and the
main frame. All three, because the first two versions of this were not enough: gating on
"WebKit called it a link activation" is gating on a signal a scripted `click()` forges,
so a page could append an anchor to a magnet, click it itself, and put a torrent in your
client having never been touched. The handoff also sat outside the main-frame check, so
a cross-origin advert frame could reach it — and on the `.torrent` side it handed the
client whatever URL the page named, making your seedbox fetch for a stranger. A
`.torrent` URL now has to come from a host you actually use.

### Adding a site adds its search plugin

qBittorrent can search these sites itself, but only through a plugin per site, installed
by hand from a wiki of community links. Magnet keeps the two in step: add a site to the
bar and the plugin for it is installed into the client, on launch and whenever the bar
changes.

Only a built-in list of addresses is ever fetched — never one a page suggested — and
plugins are never removed, because hiding a chip for an afternoon is a reversible action
and uninstalling is not. Sites with no published plugin are named rather than passed
over, so "nothing to do" cannot be mistaken for "everything is searchable".

Where qBittorrent ships its own plugin for a site, that is the one installed. A community
fork under the same engine name does not sit alongside the official one, it replaces it —
and installing one is how you silently downgrade a working plugin. Where a site has two
plugins in circulation under *different* names, a client that already has the other one
is left alone, because two plugins for one site is not an error the client reports: it
just returns everything twice.

A plugin URL that has rotted fails silently: the client accepts the request, fetches
nothing, and ends up without the plugin. `tools/tests/run.sh --live` fetches every
address in the catalogue and checks it is still a working plugin.

### Nothing reaches the disk without you approving it

**Every direct download asks first, in a dialog** naming the file, the host and the size,
with Cancel as the default. A host you approve is not asked about again.

The dialog exists because every rule short of it failed against the real thing. The
payload that settled it — five copies of an installer, identical size, all different
hashes, which is a dropper stamping a tracking id per download — was served from the
*same domain as the site being read*. That makes it a trusted host under any rule drawn
from where a file came from, and no test of origin can separate it from a real download.
Nor is a click evidence: the usual trick listens for the first click *anywhere* on the
page and starts the download from it, so "the user clicked" is true of the fake ones too.
A modal dialog is the one surface a page cannot reach.

Cruder rules still run first, so obvious junk is refused without a dialog at all: a host
with no relationship to the page being read does not get to offer a file, and a file host
you genuinely use is added once under Settings → Downloads.

Both doors are gated. A download that begins as a navigation **action** never reaches the
response policy step at all — `<a download>` and a script-synthesised click come through
that way — so a check placed only on the response is not a check.

What is approved lands on this Mac first and moves to the share once whole: a download
writes incrementally, and doing that over SMB is slow and leaves half-written files when
the link drops. Where it goes is decided by **what the site is**, using the same
categories that group the bar. Point the archive root at a folder nothing else manages —
if it is somewhere a media pipeline watches, captured files get imported and renamed out
from under you.

### Blocking

uBlock Origin's own lists, converted to WebKit's native content blocker. Three things
that cost a debugging cycle each:

- **WebKit's regex is a PCRE subset, and one bad rule fails the whole list.** No `\w` or
  `\d`, no `{n,m}`, no `(a|b)`, ASCII only.
- **`ignore-previous-rules` only cancels within the same compiled list**, so every block
  chunk must carry the full exception set or sites silently over-block.
- uBO's cosmetic filters must be stripped before the network parser sees them.

**Lists rot, and that failure is invisible.** uBO refreshes EasyList every few days
because ad hosts rotate constantly; a snapshot a month old blocks last month's networks
while this month's walk in and install their scripts — and the shield still reads
"Blocking" the whole time, truthfully, about a list of yesterday's threats. The build
refreshes lists older than a week, keeping the previous set if the network is down, since
stale beats none. The status line reports how many lists compiled versus shipped, and
names their age once it passes ten days.

Self-hosted banners are handled separately, by shape and destination: an image at least
300px wide with an aspect ratio of 3 or more, pointing off-domain. Both conditions are
required, which is what keeps a poster and a site's own announcement visible.

### Redirects are an allow-list over the window

A navigation leaving your sites is blocked silently unless a person approves it, in a
dialog, per domain, per session. Refusing a host silences it for the session, and for a
few seconds after any refusal newcomers are blocked silently rather than asked about.

The design before this one — "click the link again to go there" — was bypassed in the
wild, and the mechanics are worth recording. A script calling `click()` on an anchor it
just made reports as a link activation, indistinguishable from a real one; and the armed
confirmation was honoured for *any* later navigation to the same URL. So the advert fired
twice and confirmed itself.

The dialog is also only *earned* by a real click. An in-page listener, running in an
isolated content world, records what trusted events actually land on: `isTrusted` is set
by the engine and cannot be forged, and the isolated world keeps the page from reaching
the reporting channel to lie instead. Both properties are measured in a live `WKWebView`,
not assumed. A "link activation" with no real click on a link to that destination behind
it is a script navigation in a costume, and is blocked silently.

The net effect: a hijack firing off your clicks produces neither a redirect nor a dialog —
nothing at all — while a link you genuinely clicked asks once per domain and then
remembers.

### Sites keep their own appearance

There was a restyling engine here: five themes, one typeface and palette across every
site, backgrounds stripped, logos replaced with text. It is gone.

It could not be reconciled with the content blocker. Both want authority over the same
elements — the blocker hides things, the restyler repaints everything it can reach — and
adverts kept surfacing through the repaint. Two systems rewriting the same DOM with
opposite intentions is not a bug to be found and fixed; it is the arrangement itself.
Blocking is the one of the two that matters, so restyling went.

What survives is page zoom, in Settings → Appearance, defaulting to 105%. It uses page
zoom rather than magnification, so the layout reflows instead of the finished picture
being scaled up and the right-hand column of a table pushed off the window.

### The "blank listings" symptom

During Cloudflare's ~6s check, a site serves its own shell with zero rows, which looks
like the blocker broke it. It has not: measured with filters on and off after settling,
the results are identical. The app covers the view with a "clearing the check" state,
capped at 15s so a stalled challenge still becomes clickable.

Diagnose anything in this class by A/B-ing rule lists **and waiting for render** — an
early probe lies.

### One thing it deliberately does not do

**It never hands a page to another application on its own.** A link asking for a new
window is dropped rather than opened, because on these sites that request is almost
always the advertising rather than the content. Two narrow exceptions: a magnet arriving
that way still reaches your client, and a download link that wants a new tab loads in the
existing view instead, so nothing new is opened and the file still has to pass the
download check.

**Open in Browser** is not an exception to this. It is the same rule from the other side:
handing a page off is a thing you do, never a thing a page does.

## Testing

`tools/tests/run.sh` runs eight offline suites — bookmarks, settings, wikipedia, fmhy,
categories, banners, downloads, plugins — plus a hygiene check that greps the tree for
anything identifying one person's setup. `--live` adds two that need network: mirror
resolution against the real articles, and fetching every search-plugin URL in the
catalogue to confirm it is still a working plugin.

## Safety

- **Do not expose the forward proxy to the internet.** It will fetch anything, for anyone
  who can reach it. A tailnet or LAN only.
- **Point the archive root at a folder nothing else manages.** An import folder watched by
  a media pipeline will pick captured files up, rename them and move them.
- **Cleartext HTTP needs an App Transport Security exception**, listed in `local.env`.
  Without one the request fails before it leaves the process.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with any of the sites this can be pointed at, nor with uBlock Origin,
qBittorrent, or FMHY.

---

<p align="center">
  <img src="assets/app-icon.png" alt="The Magnet app icon" width="96">
</p>
