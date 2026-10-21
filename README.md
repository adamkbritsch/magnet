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

It has two sides. **Manual** is the browser: you look, and you pick. **Automatic**
follows the TV shows you choose and, when a new episode airs, finds it on those same
sites, reads what the release actually contains, and downloads it to your seedbox with
no browser involved. The sites in the bar are the sites it searches.

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
      ├──"Open in Browser"──▶  your default browser, directly, outside the tunnel
      │
      └──Automatic mode──▶  nas/automatic  ──▶  Sonarr ──▶ the gate ──▶ qBittorrent
                            (your NAS)          the bar's sites ──▶ Prowlarr indexers
```

- **`macapp/`** — SwiftUI, built with plain `swiftc`. No Xcode project.
- **`tools/`** — the filter-list converter, test suites, and fixtures.
- **`nas/`** — a tinyproxy container for the forward proxy (`nas/fwd`), and the service
  behind Automatic mode (`nas/automatic`).

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
| **Automatic** | The NAS service behind Automatic mode, its token, the seedbox sign-in it needs, and which of your sites it can search |
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
- Automatic mode is optional too. It needs a Docker host (a NAS, typically) running
  Sonarr, ideally Prowlarr, and the service in `nas/automatic`; Plex is used for
  suggestions if it is there. Until it is set up, Automatic mode shows how.

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

uBlock Origin's own lists, converted to WebKit's native content blocker. Four things
that cost a debugging cycle each:

- **"uBlock filters" is not one file.** uBO splits its own set by the year a rule was
  added: `filters.txt` holds only the current year's, and everything before that lives
  in `filters-2020` … `filters-2026`, `filters-general` and `quick-fixes`. Fetching
  `filters.txt` alone ships the newest slice of uBO's knowledge and none of the
  accumulated rest.

- **WebKit's regex is a PCRE subset, and one bad rule fails the whole list.** No `\w` or
  `\d`, no `{n,m}`, no `(a|b)`, ASCII only.
- **`ignore-previous-rules` only cancels within the same compiled list**, so every block
  chunk must carry the full exception set or sites silently over-block.
- uBO's cosmetic filters must be stripped before the network parser sees them.
- **A type WebKit lacks must not be widened into one it has.** `$ping` means a beacon;
  the nearest WebKit type is `raw`, which is every XHR and fetch. So `*$ping,third-party`
  — block third-party beacons — became *block all third-party XHR on every site*, which
  is most of the modern web and, specifically, the request a Cloudflare challenge makes.
  One rule, and nothing behind Cloudflare would load. A rule that cannot be narrowed is
  dropped, and the suite now fails on any block rule that matches everything and is
  scoped to nothing.
- **uBO lets a regex stand where a hostname goes** — in `$domain=` and before `##`.
  WebKit's `if-domain` takes hostnames only, so one passed through plants a `^` inside
  a domain pattern, which it rejects. Compilation is all-or-nothing, so **four such
  rules out of 144,000 silently took two of the four lists out of service** — half the
  blocking gone while the shield still read "Blocking". `tools/tests/run.sh` now
  compiles every list, because nothing about the app's behaviour reveals this.

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

**`window.open` was the one technique that still worked**, and it is worth recording
how. The popup itself was dropped, as designed — and then its URL was loaded into the
main view instead, arriving as an ordinary navigation nobody had judged. The gate was
"could this be a download?", which answered yes to *any* http address opened from a
page in the bar. A popup is now followed only when it points at a **file**; an advert
points at a page. `tools/tests/run.sh` checks all twelve techniques against the real
policy, and checks the other direction too, since a fix that broke "download link opens
in a new tab" would be a different bug rather than a fix.

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

## Automatic downloads

Switch with the control beside the home button, or **Cmd-1** and **Cmd-2**. The browser
stays exactly where you left it while Automatic mode is showing, and Cmd-R refreshes
whichever side you are looking at.

| Pane | What it is |
|---|---|
| **Following** | The shows whose new episodes are downloaded. Search to follow another. |
| **Coming Up** | The last three days and the next four weeks, with where each episode is: aired and waiting for a release, downloading, on the seedbox, or on the NAS. |
| **Seedbox** | What has downloaded, with **Bring to NAS**. |
| **Blocked** | Every release that was refused, why, and the files that did it. |
| **Suggestions** | Shows still airing that you picked by hand in the browser, or have been watching in Plex. |

### How a new episode arrives

**Sonarr** watches the calendar for the shows you follow and searches when an episode
airs. It hands the release it chose to its download client — which is not qBittorrent
but **the gate**, a small service on the NAS that speaks qBittorrent's API. The gate
passes everything through to the seedbox's real qBittorrent except adding a torrent:

- a `.torrent` file is read on the NAS, and a release that breaks the rules never
  reaches the seedbox at all. One that passes still goes in **stopped**: the list that
  is judged before anything downloads is qBittorrent's own reading of it, because a
  crafted file can read one way to one parser and another way to libtorrent;
- a magnet is added with `stopCondition=MetadataReceived`, so qBittorrent fetches the
  file list and then stops by itself. The gate reads the list and either starts the
  torrent or deletes it.

A refused release is marked failed in Sonarr, which blocklists it and searches again.
Sonarr only ever hears "Ok.", so a refusal never puts the download client into
back-off. The real qBittorrent sign-in lives only in the gate; Sonarr gets a separate
local login that is worthless anywhere else.

### The sites decide where it searches

The bar's sites — the home site included — are sent to the NAS whenever they change.
Each is matched to a public Prowlarr indexer whose domains, mirrors included, share a
domain with it, and only indexers that can search TV count. Those carry a
`magnet-sites` tag, and so does Sonarr's entry in Prowlarr, so Prowlarr syncs exactly
those indexers to Sonarr. Add a site to the bar and it is searched; hide or remove it
and it stops.

It tags rather than enables or disables, on purpose: anything else syncing from the
same Prowlarr (Radarr, say) keeps every indexer it had, an indexer is never deleted, and
one you turned off in Prowlarr stays off. If none of the sites can be searched for TV,
Sonarr is not restricted at all — it keeps every indexer rather than ending up with
none. **Settings → Automatic** lists each site with what became of it: searched, no TV
on this site, no indexer exists for it, needs an account, or turned off in Prowlarr.

Two things to know. An indexer added for one of your sites is new to Prowlarr, so any
app that syncs every indexer (Radarr, with no tags) gets it too; tag that app in Prowlarr
if it should not. And with more than one Sonarr in Prowlarr, name the one behind the gate
in `PROWLARR_SONARR_APP`, or nothing is restricted.

### What a release may contain

Video, subtitles, and a few text or image extras. A release is refused outright when:

- **any file is an executable.** `.exe`, and the same thing under another extension:
  `.scr .com .pif .bat .cmd .msi .msp .msix .appx .lnk .cpl .dll .sys .drv .ocx .vbs
  .vbe .js .jse .wsf .wsh .ps1 .psm1 .hta .jar .reg .scf .inf .application .gadget
  .msc .chm .xll .wsc .sct .ws .appref-ms .library-ms .settingcontent-ms .diagcab
  .search-ms .msu .cab .url`, disk images Windows mounts on a double-click (`.iso .img
  .vhd .vhdx`), and the macOS equivalents (`.app .dmg .pkg .mpkg .command .sh .apk
  .webloc .inetloc .fileloc .terminal .tool .workflow`), or anything inside an `.app`
  bundle. The extension is what follows the last dot, after removing invisible
  characters (the right-to-left override that makes `Episode<RLO>vkm.exe` look like a
  video) and the trailing dots and spaces Windows ignores — so `..exe` is an `.exe` too;
- **there is no video file of episode size** (50 MB or more);
- **the largest file is not a video** — a sample clip beside a large archive.

`.scr` is on the list because it was the real thing: a 0.9 GB `<hash>.scr`, grabbed by
an earlier setup for a TV episode. The file list is checked again at Bring to NAS.

### What makes a release good

Sonarr chooses between releases by score, and `setup_sonarr.py` builds the score from
[TRaSH Guides](https://github.com/TRaSH-Guides/Guides)' custom formats (vendored, MIT, in
`nas/automatic/formats/`) — the community-maintained patterns for HDR type, audio,
source, release-group reputation and known-bad releases. The weights are Magnet's, and
each tier outweighs everything below it put together, so the order is strict:

| What | Score |
|---|---|
| **Dolby Vision** | +10000 (−200 when there is no HDR10 fallback layer) |
| 2160p / 1080p | +3000 / +500 |
| HDR10, HDR10+ (+100 more), and other HDR | +1000 |
| Release group: remux tiers, Blu-ray tiers, web tiers | +600 to +900 |
| Audio: TrueHD Atmos down to Dolby Digital | +40 to +300 |
| Hybrid, streaming-service boosts, repacks, internal | +5 to +100 |
| No release group at all | −500 |
| A tracker's tag on the title (`[TGx]`, `[EZTVx.to]`) | −50 |
| A low-quality encoder (TRaSH's LQ list) | −1000 |
| Banned: upscales, obfuscated names, AV1, x266, disc images, extras, bad dual-audio groups, audio only in a language the show was not made in, an executable at the end of the title | −100000 |

The minimum to be taken at all is −1000, so a low-quality encode can still be the first
copy when it is all there is — anything better replaces it within the week. TRaSH bans
those outright, but its bans are tuned for private trackers; on public ones they are
often what arrives first. The language rule is "not the original language" rather than
"not English", so a Korean or Japanese show is not banned for being Korean or Japanese.

Setup also sets Sonarr's **Propers and Repacks** to *Do not prefer*. Left at its default,
Sonarr ranks a REPACK above any score — a 1080p repack would beat a Dolby Vision
release. The repack formats (+5 to +7) still break ties.

1080p and 2160p from every source share one quality tier, so it is the score that
decides. Otherwise Sonarr ranks by source first, and a Blu-ray without Dolby Vision would
beat a web release with it before the score was looked at. **That is what makes Dolby
Vision win every time.** 720p is a fallback below them.

Two of TRaSH's usual bans are deliberately left out: x265 at 1080p, and 2160p SDR. Both
are things worth having when they are what exists.

Minimum sizes per minute of runtime (2160p web: 15 MB/min, about 2 Mbps) keep a
"2160p" that is 300 MB from ever being taken.

### A copy as soon as there is one, a better one within the week

Sonarr checks the indexers' new releases every 15 minutes and takes the first acceptable
one. The **scout**, in the NAS service, covers what that misses:

- **As soon as an episode airs** with nothing grabbed, it asks Sonarr to search: every 20
  minutes for six hours, then every two hours.
- **For seven days after the first copy**, it asks again every six hours. Sonarr takes a
  release only when it beats the queued one by at least 100 points — a real step, like
  Dolby Vision over HDR10, not a repack tag.
- **When the week is over** the episode is unmonitored, so nothing replaces it again.
- **A better copy that has finished downloading retires the worse one** from the seedbox,
  unless that one is on its way to the NAS. A season pack stays until every episode in it
  has something better.
- **A download that stops moving** — no progress for three hours, or a magnet whose file
  list never arrives in two — is dropped and marked failed, and Sonarr takes the next best.
- **A first copy too slow to be one** — the episode's only copy, still more than four
  hours from done after half an hour — is traded for the next best the same way. An
  upgrade may take as long as it likes; there is already a copy.
- Only a live copy counts. A grab the gate refused, or one dropped as stalled, does not
  stop the hunt for a first copy, and an episode is never left alone after its week
  unless it has a copy that finished.

The window, the pace and the clean-up are settings in the service's `.env`
(`SCOUT_WINDOW_DAYS`, `SCOUT_UPGRADE_EVERY_HOURS`, `SCOUT_STALL_HOURS`,
`SCOUT_REMOVE_SUPERSEDED`, `SCOUT_FIRST_COPY_MAX_HOURS`).

### It reads qBittorrent the way its window does

Every decision about a download is made from what qBittorrent's own list would show for
it — Downloading, Stalled, Queued, Checking, Stopped, Completed, Missing Files — worked
out from its state, progress and bytes left, not from the progress figure alone.

- **Finished** means every byte is there and no check is running. Only a finished copy
  can be brought to the NAS or retire an older one; while qBittorrent is checking, the
  progress it shows is the check's, and nothing acts on it.
- **Stopped with data still to fetch** — what qBittorrent does when a check finds pieces
  missing on a torrent that was stopped — is started again. Six restarts in an hour is
  a fight, not a fix: it stops trying, and the scout replaces the release.
- **Errored or missing its files** is rechecked, then resumed; replaced only if that
  does not bring it back.
- **Checking, moving or allocating** is never counted as stalled and never interrupted.

The Seedbox pane shows the same words. The Seedbox pane shows, for each copy, what made it good and
how long the search for a better one has left.

### New episodes only

Following a show monitors only the episodes that have not aired yet, and setting up
unmonitors every episode that already has. Monitoring a back catalogue means any old
episode that turns up in a feed becomes a download — which is how decade-old episodes,
and that `.scr`, arrived. Unfollowing only stops monitoring; nothing is deleted.

### Nothing moves to the NAS until you say so

An episode waits on the seedbox until you press **Bring to NAS**. Sonarr then copies it —
copies, so the seedbox keeps seeding — into the show's folder with its usual naming, and
the media server picks it up.

### When Sonarr is paused

Some NAS setups pause containers while a stream is playing, so playback never stutters.
A paused container accepts a connection and then never answers, which would leave
everything waiting on a timeout. The service probes Sonarr with a three-second timeout
instead, says so ("Sonarr is paused while Plex is streaming"), and keeps the seedbox view
working. Sonarr catches up when it resumes; the site list waits for Prowlarr the same way.

### Setting it up

1. On the Mac, add `MAGNET_NAS_SSH` and `MAGNET_NAS_DIR` to `local.env`, and copy
   `nas/automatic/site.env.example` to `site.env` (gitignored) with your seedbox, paths
   and service addresses.
2. `nas/automatic/deploy.sh --token` copies the service to the NAS, generates its
   secrets there the first time, starts it, and puts the API token where Magnet reads it
   (`~/Library/Application Support/Magnet/automatic-token`, mode 600).
3. On the NAS, `python3 setup_sonarr.py --plan`, then without `--plan`. It changes
   nothing at all until Sonarr can reach the gate (so do step 4 first), then switches
   everything at once: the profile, the gate as the only torrent client, Completed
   Download Handling off (an episode reaches the NAS only through Bring to NAS), and
   new episodes only. It is idempotent, snapshots what it changes, and keeps the state
   from before its first run as `rollback/sonarr-original.json` — the file
   `rollback_sonarr.py` takes to undo all of it.
4. In Magnet, Settings → Automatic: the service's address (a plain-http host also goes in
   `MAGNET_HTTP_HOSTS`), then **Send Magnet's Sign-In**. It is checked against the seedbox
   once and kept only on the NAS. A refused sign-in is never retried by itself, because
   qBittorrent bans an address after a few failures, and that address is the NAS's.

## Testing

`tools/tests/run.sh` runs fourteen offline Swift suites — bookmarks, settings, wikipedia,
fmhy, categories, banners, downloads, plugins, choicelog, qbsession, redirects,
pagesafety, blocklists, automatic — then the Automatic service's Python tests (the gate,
the file rules, qBittorrent and Sonarr conversations, and the sites-to-sources sync,
and the scout, against in-process fakes), a check that every site probe goes through the proxy, and a
hygiene check. Hygiene scans what is staged, the working copies and new files —
Markdown included — for home directories, tailnet addresses and NAS volume paths, plus
whatever you list in `tools/hygiene.local` (gitignored, one regex per line: your own
hostnames and names, which the check could not list without publishing them). `--live` adds two that need network: mirror
resolution against the real articles, and fetching every search-plugin URL in the
catalogue to confirm it is still a working plugin.

## Safety

- **Do not expose the forward proxy to the internet.** It will fetch anything, for anyone
  who can reach it. A tailnet or LAN only.
- **Point the archive root at a folder nothing else manages.** An import folder watched by
  a media pipeline will pick captured files up, rename them and move them.
- **Cleartext HTTP needs an App Transport Security exception**, listed in `local.env`.
  Without one the request fails before it leaves the process.
- **Keep the Automatic service on a LAN or tailnet.** Its API wants a token and its gate
  listens only on the Docker bridge, but neither is meant for the internet. The token,
  the gate password and the seedbox sign-in live in gitignored files only their owner
  can read.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with any of the sites this can be pointed at, nor with uBlock Origin,
qBittorrent, Sonarr, Prowlarr, Plex, or FMHY.

---

<p align="center">
  <img src="assets/app-icon.png" alt="The Magnet app icon" width="96">
</p>
