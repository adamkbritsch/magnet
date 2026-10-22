<p align="center">
  <img src="assets/app-icon.png" alt="Magnet" width="128">
</p>

<h1 align="center">Magnet</h1>

**A browser shaped for the sites it is pointed at.**

Torrent sites are a browser's worst case. They move domain without warning, they are
wrapped in advertising that a general-purpose browser only partly removes, they start
downloads you did not ask for, and they hand you a magnet link that then has to find its
way to a torrent client somewhere else. Magnet treats all of that as the application's
problem rather than yours.

One window holds the whole job:

- **Manual** — the browser. Every request goes through a proxy you control, a site that
  stops answering is looked up under its other domains, a magnet goes straight to your
  client, and a direct download has to be approved before it can touch the disk.
- **Automatic** — new episodes of the TV shows you follow, found on the same sites, checked
  for what the release really contains, and downloaded to your seedbox on their own.
- **qBittorrent** — the client's own web interface, in a pane beside the browser.
- **Files** — the seedbox, your NAS and this Mac as file browsers over a transfer queue,
  for moving what has finished to where it belongs.

The window takes qBittorrent's look throughout, so all four read as one app. Magnet ships
with no sites, no home page and none of your services; everything is set up in Settings.

## Why

For most of the web, a normal browser with an ad blocker is the right answer. Here it
falls down in four places:

- **A blocker cannot reach a self-hosted ad.** Filter lists block advertising networks by
  hostname. A site's own affiliate banner is served from its own domain, so no list
  contains it.
- **A bookmark is a fixed address, and these addresses are not fixed.** Domains are seized
  and rotated; a bar full of dead links is the normal end state.
- **A magnet link is a handoff to a program somewhere else** — usually a client on a
  seedbox or a NAS, behind a network that may not welcome the connection. A browser's job
  ends at "open in application", which is the wrong end.
- **A download here is guilty until proven innocent.** These pages start downloads from a
  click on anything at all.

If blocking is all you want, any browser running [uBlock Origin](https://github.com/gorhill/uBlock)
blocks more than Magnet can: uBO runs scriptlets and procedural filters that WebKit's
content blocker has no equivalent for. Magnet converts uBO's lists into WebKit's native
blocker, accepts the loss of the dynamic parts, and in exchange does what an extension
cannot — knows which domains are alternates of each other, posts magnets to your client,
decides where a downloaded file belongs, and keeps your client's search plugins in step
with your sites.

## How it fits together

```
   macOS app  ──always──▶  CONNECT proxy  ──▶  the site
    Magnet                 (yours, anywhere)
      │
      ├──magnet link───▶  qBittorrent Web API   (client, wherever it lives)
      ├──search plugin─▶  qBittorrent Web API
      ├──qBittorrent pane▶ qBittorrent WebUI     (directly, not through the proxy)
      │
      ├──direct file───▶  this Mac  ──when whole──▶  SMB share
      │                   (after you approve it)
      │
      ├──open in browser─▶  your default browser, directly, outside the tunnel
      │
      ├──Automatic─────▶  nas/automatic  ──▶  Sonarr ──▶ the gate ──▶ qBittorrent
      │                   (your NAS)          the bar's sites ──▶ Prowlarr indexers
      │
      └──Files─────────▶  the Shuttle relay   ──▶  seedbox ⇄ NAS, and either ⇄ this Mac
                          (your NAS)
```

- **`macapp/`** — SwiftUI and AppKit, built with plain `swiftc`; no Xcode project.
  `macapp/shuttle/` is Files.
- **`nas/`** — a tinyproxy container for the forward proxy (`nas/fwd`) and the service
  behind Automatic (`nas/automatic`). The relay Files talks to lives in the Shuttle
  repository, not here.
- **`tools/`** — the filter-list converter, the test suites and their fixtures.

## Requirements

- macOS 14 or later, on Apple silicon (the build is arm64 only). Building needs Xcode's
  command line tools; the icon step also wants Xcode itself and is skipped without it.
- Python 3, for the filter-list converter.
- **A forward (`CONNECT`) proxy you can reach.** Required — see below.
- Optional, and dormant until configured: a qBittorrent Web API (magnets, search plugins,
  the qBittorrent pane), an SMB share (download filing), the Shuttle relay (Files), and a
  Docker host running Sonarr, Prowlarr and `nas/automatic` (Automatic; Plex is used for
  suggestions and for saying why Sonarr is paused, if the service can see it).

## Install

**1. Build it.** Copy `local.env.example` to `local.env` and give it a bundle id of your
own — it is where your settings live and how macOS recognises the app, so pick one and
keep it. Any service you reach over plain `http` (qBittorrent, the Automatic service, the
Files relay) also goes in `MAGNET_HTTP_HOSTS`, exactly as the host appears in Settings:
macOS refuses plain-HTTP requests to any other host, and the list is read at build time,
so a change needs a rebuild.

```bash
cp local.env.example local.env
./macapp/build.sh --install
```

The first build converts uBlock Origin's filter lists, which needs network and takes a few
minutes; if it cannot, the app is built without content blocking and the next build tries
again. Later builds reuse the lists and refresh them once they are a week old, keeping the
previous set if the refresh fails.

The build signs the app with a certificate it creates in your login Keychain the first
time, so macOS sees the same app after every rebuild. `--install` replaces the copy in
`~/Applications`, restarts it if it is running, and removes its own build output so only
one bundle with your id can be launched.

**2. Open it** from `~/Applications`. A copy built on your own Mac is not quarantined, so
it opens without a Gatekeeper prompt.

**3. Set it up in Settings.** A proxy and a home site are required; the rest is optional.

| Tab | For |
|---|---|
| **Sites** | The home site, the sites in the bar, and a Firefox bookmark folder to mirror |
| **Connection** | The forward proxy every request goes through — **required** |
| **Torrent Client** | The qBittorrent Web API and its sign-in: magnets, search plugins and the qBittorrent pane |
| **Files** | The relay's address and token, the seedbox it reaches, and how many copies it runs at once |
| **Automatic** | The NAS service, its token, the seedbox sign-in it needs, and which of your sites it can search |
| **Downloads** | The SMB share approved downloads are filed into, and file hosts allowed to send them |
| **Mirrors** | Your mirror sets, and FMHY's published list |
| **Appearance** | Page zoom |
| **Blocking** | Filter-list status, count and age |

**4. Choose "Always Allow" when macOS asks about the Keychain.** The proxy's and
qBittorrent's sign-ins share **one** Keychain item, read once per launch, so there is one
question to answer. A build without an Apple Team ID is a new identity to the Keychain each
time it is rebuilt, so a rebuild asks once more; answering "Allow" alone asks every launch.

## Keyboard

| Keys | Does |
|---|---|
| ⌘1 / ⌘2 | Manual / Automatic |
| ⌘3 | Show or hide Files |
| ⌃⌘S | Show or hide the qBittorrent pane |
| ⌘R | Reload the side you are using — the qBittorrent pane when it has the keyboard, otherwise Files, Automatic or the page. On a page still loading, stop it. |
| ⌘[ | Back |
| ⇧⌘H | Home |
| ⌘, | Settings — on the Files tab while Files is showing |
| ⌃⌘F | Full screen |

In Files: ⌘↩ send the selection, ⌘↑ enclosing folder, ⌘⌫ stop the selected transfer,
⌘F find, ⇧⌘F favorites, ⌘D add the folder to favorites. These act only while Files is on
screen and the keyboard is not in qBittorrent; ⌘↩, ⌘↑ and ⌘⌫ also leave a text field
alone when one has the keyboard.

## The browser

### Everything goes through the proxy

There is one route: a forward proxy of yours, typically on a NAS over a tailnet. If it
does not answer, nothing loads and the app names the address that failed. There is no
fallback by design — a tunnel that silently stops being used looks exactly like one that
works. A change of proxy in Settings → Connection takes effect as soon as you stop typing.

It **must** be a forward (`CONNECT`) proxy, not a reverse one:

| Path | Cloudflare challenge |
|---|---|
| `curl`, direct | 403 |
| `WKWebView`, direct | solved in ~6s |
| `WKWebView` through a Caddy **reverse** proxy | never solved |
| `WKWebView` through an HTTP **CONNECT** proxy | solved in ~6s, same as direct |

A reverse proxy terminates TLS and rewrites the origin, so the challenge cannot validate;
`CONNECT` tunnels raw TLS to the origin and Cloudflare sees an ordinary browser.
Cloudflare Tunnel carries HTTP services but not CONNECT proxies, so reaching the proxy
from away needs a VPN or tailnet. The app's probes of sites live in `Mirrors.swift` and go
through the same proxy; `tools/tests/run.sh` fails if that file ever builds a bare
`URLSession`.

The **open-in-browser** button (an arrow leaving a box, next to the route indicator) is the
deliberate way out: it hands the current page to your default browser, reached directly,
for anything this app will not do — a sign-in, a payment page, a download it refuses. When
nothing has loaded yet, as when the proxy was down at launch, it opens the home site. In
the browser this is the only handoff, and it is always yours; a page can never hand itself
off.

### The bar

Sites come from a Firefox bookmark folder, from sites added by hand, or both, grouped into
**Everything**, **Movies & TV**, **Games** and **Books**, plus **Other** when anything is
in it. A small built-in table knows which section the well-known sites belong to; any other
site starts in Other until you drag its chip to a section or choose **Move to Section**
from its right-click menu. Click a section icon to fold it away. A site's section also
decides which folder its downloads are filed into.

### A site that stops answering is looked up elsewhere

When a page fails at the transport layer, the app probes the site's other domains,
switches to one that answers, and remembers it. At each launch, or with Settings →
Mirrors → **Refresh Now**, it tries the set's preferred domain again and goes back to it
once it answers. Right-click a chip to pick a domain by hand. An HTTP rejection — a
Cloudflare challenge above all — proves the domain is alive, so it never causes a switch.

Domain lists come from mirror sets you define in Settings → Mirrors. A set can name a
**Wikipedia article**, whose infobox is re-read for the current domains, so a site rotating
domains under takedown keeps working without an update. FMHY's published list is used too
unless you turn it off there: fetched through the proxy at launch, at most every six hours
by default, it adds mirrors for hundreds of sites, and your own sets always win.

### Magnets go straight to the client

Magnet and `.torrent` links are posted to the qBittorrent Web API set in Settings →
Torrent Client, with its saved sign-in — without one, nothing is sent, even to a client
that does not ask for one. Point it at a reverse proxy in front of the client rather than
the client's own port, and it works on networks that block that port.

A magnet is sent only when it carries a real info hash, came from the main frame, and
follows a real click on a link to **that** torrent — clicks are recorded from trusted
events, in an isolated content world the page cannot reach, so a script calling `click()`
on a link it made does not count. A `.torrent` URL must come from a host you use, so a
page cannot make your seedbox fetch for a stranger.

Every torrent you choose is also logged, on this Mac only, to
`~/.claude/prompt-log/torrent-choices.jsonl`: its name, info hash, the page it was picked
from and that page's search terms. Automatic's Suggestions read it. Nothing is sent
anywhere.

### Adding a site adds its search plugin

Add a site to the bar and its qBittorrent search plugin is installed into your client.
This runs whenever the bar's sites differ from the set last synced (checked at launch and
on every change), or when you press **Sync Now** in Settings → Torrent Client, where the
switch for it lives; it needs the saved sign-in. Only addresses from a built-in catalogue
are ever fetched — never one a page suggests — and plugins are never removed, so one you
remove in qBittorrent comes back only after the bar changes or a Sync Now. Where
qBittorrent ships its own plugin for a site, that is the one installed, and a site is
never given a second plugin under another name. Sites with no published plugin are named,
so "nothing to do" cannot pass for "everything is searchable". A plugin URL that has
rotted fails silently in the client; `tools/tests/run.sh --live` fetches every one.

### Nothing reaches the disk without you approving it

Every direct download asks first, in a dialog naming the file, the host and the size, with
**Cancel** as the default. Tick **Always allow downloads from** the host and that exact
host is not asked about again.

A dialog, because no rule short of one can tell a real download from a fake: decoys are
served from the same domain as the page, and the usual trick starts the download from the
first click *anywhere* on the page, so "the user clicked" is true of them too. A modal
dialog is the one surface a page cannot reach. Cruder rules still run first, so obvious
junk is refused without asking: a host with no relationship to the page cannot offer a
file at all, a frame can load a page but never hand over a file, and both ways a download
can start — as a navigation and as a response — are checked. A file host you really use
goes in Settings → Downloads, exactly as the refusal names it; hosts listed there skip the
dialog too.

What is approved downloads to a staging folder on this Mac (`~/Magnet-Library` unless
changed) and moves to the SMB share once whole, into the share's folder (**Direct** by
default) and then a folder for the site's section. The share's password comes from your
login Keychain: connect to it once in Finder, or answer macOS's dialog on the first
download, and let it remember the password. If the share cannot be mounted, files stay on
this Mac and Magnet stops trying until you click a site in the bar. Point the folder on
the share at one nothing else manages — a folder a media pipeline watches will have files
imported and renamed out from under you.

### Blocking

uBlock Origin's own lists — uBlock filters with every yearly file, plus its privacy,
badware, resource-abuse, quick-fixes and unbreak lists — and EasyList, EasyPrivacy and
Peter Lowe's ad-server list, converted to WebKit's native content blocker: well over a
hundred thousand rules. The converter works within WebKit's limits: its regex subset, the
all-or-nothing compilation of each list, `ignore-previous-rules` only cancelling within
one list, and hostnames only where uBO allows a regex. A beacon rule (`$ping`) is never
widened into one for every XHR and fetch, and a block rule that would match every URL
with no domain scope is dropped. `tools/tests/run.sh` compiles every shipped list.

Settings → Blocking shows how many lists compiled and names their age once it passes ten
days; a build refreshes them.

Self-hosted ads are handled separately, by shape and destination: anything sized like a
standard ad slot (an image, frame, video, `<ins>` or background) and any image at least
300px wide and three times wider than tall, when it links to or is served from another
site. Empty transparent links laid over most of the window are removed whatever their
destination. Verification widgets such as Cloudflare's Turnstile are never touched, and
the scroll locks anti-adblock walls use are released.

### Leaving your sites needs a person

A navigation leaving your sites is blocked silently unless you approve it, in a dialog, per
domain, per session. Refusing a host silences it for the session, and for eight seconds
after a refusal any other new destination is blocked without asking. The dialog is only
offered after a real click on a link to that destination, recorded the same way as for
magnets — a "link activation" with no such click behind it is a script navigation and is
blocked without asking. The net effect: a hijack set off by your clicks produces neither a
redirect nor a dialog, while a link you meant asks once per domain.

A page asking for a new window is never given one; on these sites that is almost always the
advertising. A magnet arriving that way still reaches your client after a real click on
it, and a new window that a site in the bar opens on a file address (one ending in a file
extension) loads in the current view if it is on one of your sites, where it still has to
pass the download check. `tools/tests/run.sh` checks these techniques against the real
policy in both directions.

### Page zoom, and Cloudflare's check

Sites are drawn at 105% by default (Settings → Appearance), with page zoom rather than
magnification so the layout reflows instead of being cut off at the right.

During Cloudflare's few-second check a site often shows its shell with no rows, which looks
like blocking broke it. The view is covered with a "clearing the check" state instead, for
at most 15 seconds so a stalled challenge still becomes clickable.

## qBittorrent in the same window

The client's own web interface, at the address in Settings → Torrent Client and with the
same saved sign-in. The sidebar button at the left of the bar and ⌃⌘S appear once that
address is set; the pane is shown from then on until you hide it, and shown or hidden is
remembered across launches.

| Window | qBittorrent |
|---|---|
| 1480pt wide or more | The left half, side by side |
| Narrower | The top half, above the rest |
| Hidden | Slides off the edge it came from |

Drag the line between the two to resize; double-click it to split evenly. The position is
remembered as qBittorrent's share of the window, separately for side by side and stacked,
so it keeps its proportion as the window changes size. Side by side, qBittorrent keeps at
least 400pt and the right-hand side 740pt (enough for Magnet's bar and Files' two panes);
stacked, 240pt and 380pt. The window itself is at least 900 × 640pt.

The pane reaches qBittorrent directly, not through the forward proxy, with cookies of its
own, so its address must be reachable from this Mac (and listed in `MAGNET_HTTP_HOSTS` if
it is plain HTTP). It loads the first time it is shown and signs in inside the page,
reading the Keychain only when there is no session already. A sign-in counts once
qBittorrent answers an authenticated request afterwards, which covers both the `200 Ok.`
and the empty `204` that different versions return. After two refusals it stops trying
for the launch, and a 403 — qBittorrent's ban — stops it at once: qBittorrent bans an
address after a few failures, and if you reach it through a reverse proxy on your NAS,
that address is the NAS's, so a ban would also cut off magnets and Automatic's gate.
Saving the sign-in again in Settings → Torrent Client clears the count and tries again.

A file the interface hands over, such as an exported `.torrent`, is saved straight to
`~/Downloads`. A link to another site opens in your default browser.

## Files

Two file panes over a transfer queue, covering the whole right-hand side, bar included,
with qBittorrent still beside it. Each pane can show the seedbox, your NAS or this Mac, and
never the same one as the other (the seedbox and the NAS by default). Open it with the
**Files** pill at the right end of the bar, or ⌘3; the pill sits in the same place in both
bars, so the click that opens Files closes it.

It drives the Shuttle relay on your NAS. A copy between the seedbox and the NAS runs
entirely between those two machines; only transfers to or from this Mac pass through the
app. It sends, replaces, moves, renames and bulk-renames, creates folders (on the NAS and
this Mac), deletes, keeps favorites, searches either side, uploads from this Mac, verifies
a finished copy's file counts, and shows a transfer's rclone log. Its settings are the
**Files** tab in Settings.

- **Renaming something on the seedbox never touches the seedbox**: it copies the item to
  the destination folder and renames the copy, so nothing that is seeding breaks.
- **A delete on the seedbox or the NAS is permanent**, and the confirmation says so; on this
  Mac, deletes go to the Trash.
- **Hidden, it stays where it was.** Its view is built the first time it is shown and then
  kept, so hiding it never loses its panes, its history or a running transfer; hidden, it
  does not poll the relay.
- **Stopping an upload.** One from this Mac to the NAS stops mid-file. One to the seedbox
  stops after the file in flight, because the relay writes those under their real names
  and a cut-off file would look complete.
- **Transfers to or from this Mac run inside the app**, so quitting or closing the window
  asks first while one is running. Transfers on the NAS carry on regardless.
- **The relay's token and address** are kept in `~/Library/Application Support/Shuttle/`,
  where other tools on this Mac also read them. If you used the Shuttle app, set
  `MAGNET_SHUTTLE_BUNDLE_ID` in `local.env` and its relay address, favorites and layout are
  copied in once.

## The look

The colours are qBittorrent's own WebUI palette (5.2.3, light and dark), used the way it
uses them: its grey chrome for bars and panels, its surface for lists and pages, orange
with white text under the pointer, and blue for whatever is chosen — a tab, the side that
is showing, the qBittorrent switch. Manual and Automatic are a tab strip, like its
Transfers / Search / RSS.

## Automatic

Switch with the tabs beside the home button, or ⌘1 and ⌘2. The browser stays exactly where
you left it while Automatic is showing.

| Pane | What it is |
|---|---|
| **Following** | The shows whose new episodes download. Search to follow another; choose **Stop Following** from a show's context menu to stop (nothing is deleted). |
| **Coming Up** | The last three days and the next four weeks, with where each episode is: aired and waiting, downloading, on the seedbox, or on the NAS. |
| **Seedbox** | Every episode download on the seedbox, finished or not, with qBittorrent's state for it, what made each copy good, how long the search for a better one has left, and **Bring to NAS** once it has finished. |
| **Blocked** | The latest releases refused and downloads dropped for not moving or being too slow — each with why, the files that did it, and whether Sonarr has blocklisted it. |
| **Suggestions** | Shows still airing that you picked by hand in the browser, or have been watching in Plex. |

### How an episode arrives

**Sonarr** picks up new releases of the shows you follow from its indexers' feeds, and the
scout (below) asks it to search as soon as an episode airs. It hands the release it picks to
its download client — which is not qBittorrent but **the gate**, a small service on your NAS
that speaks qBittorrent's API but passes on only the calls Sonarr makes, keeps them to its
own category, never starts a torrent it has not approved, and handles adding a torrent
itself:

- a `.torrent` is read on the NAS, and one that breaks the rules never reaches the
  seedbox. One that passes still goes in **stopped**, and is judged again from
  qBittorrent's own reading of its file list, because a crafted file can read one way to
  one parser and another way to libtorrent;
- a magnet is added with `stopCondition=MetadataReceived`, so qBittorrent fetches the file
  list and stops by itself; the gate reads the list and starts the torrent or deletes it.

A release that passes but finds the seedbox short of space — less than `MIN_FREE_GB`, 100 GB
by default — waits, shown as Waiting for space, and starts once there is room. A refused
release is marked failed in Sonarr, which blocklists it and searches again. Sonarr only ever
hears "Ok.", so a refusal never puts its download client into back-off. The real
qBittorrent sign-in lives only in the gate; Sonarr has a separate local login that is
worthless anywhere else.

### The sites decide where it searches

The bar's sites, the home site included, are sent to the NAS whenever they change. Each is
matched to a public, TV-capable Prowlarr indexer that shares a domain with it, mirrors
included. Those indexers and Sonarr's entry in Prowlarr carry a `magnet-sites` tag, so
Prowlarr syncs exactly those to Sonarr: add a site to the bar and it is searched; hide it
and it stops. The NAS applies a new list once Prowlarr answers and re-applies it every six
hours, so a tag removed by hand comes back. This needs `PROWLARR_URL` and
`PROWLARR_CONFIG_FILE` in `site.env`; without them, Sonarr searches with the indexers it
already has.

It tags rather than enabling or disabling, so anything else syncing from the same Prowlarr
keeps every indexer it had, nothing is ever deleted, and an indexer you turned off stays
off. If none of your sites can be searched for TV, Sonarr is not restricted at all.
Settings → Automatic lists each site with what became of it: searched, no TV on this site,
no indexer for it, needs an account, or turned off in Prowlarr. An indexer added for one of
your sites is new to Prowlarr, so an app that syncs every indexer gets it too — tag that
app if it should not. With more than one Sonarr in Prowlarr, name the one behind the gate
in `PROWLARR_SONARR_APP`.

### What a release may contain

Anything that cannot run, as long as the largest file is an episode-size video. A release
is refused when:

- **any file is an executable** — `.exe`, and the same thing under another extension:
  `.scr .com .pif .bat .cmd .msi .msp .msix .appx .lnk .cpl .dll .sys .drv .ocx .vbs .vbe
  .js .jse .wsf .wsh .ps1 .psm1 .hta .jar .reg .scf .inf .application .gadget .msc .chm
  .xll .wsc .sct .ws .appref-ms .library-ms .settingcontent-ms .diagcab .search-ms .msu
  .cab .url`, disk images Windows mounts on a double-click (`.iso .img .vhd .vhdx`), the
  macOS equivalents (`.app .dmg .pkg .mpkg .command .sh .apk .webloc .inetloc .fileloc
  .terminal .tool .workflow`), or anything inside an `.app`. The extension is read after
  removing invisible characters (the right-to-left override that makes
  `Episode<RLO>vkm.exe` look like a video) and the trailing dots and spaces Windows
  ignores, so `Setup.exe.` and `Setup.exe ` are `.exe` too;
- **there is no video file of episode size** (50 MB or more);
- **the largest file is not a video** — a sample clip beside a large archive.

The file list is checked again at Bring to NAS.

### What makes a release good

Sonarr chooses by score, and `setup_sonarr.py` builds the score from
[TRaSH Guides](https://github.com/TRaSH-Guides/Guides)' custom formats (vendored, MIT, in
`nas/automatic/formats/`). The weights are Magnet's. Dolby Vision outweighs everything below
it put together, and so does 2160p; HDR can be outscored by a top release group with the
best audio (up to +1200).

| What | Score |
|---|---|
| **Dolby Vision** | +10000 (−200 with no HDR10 fallback layer) |
| 2160p / 1080p | +3000 / +500 |
| HDR10, HDR10+ (+100 more), and other HDR | +1000 |
| Release group: remux, Blu-ray and web tiers | +600 to +900 |
| Audio: TrueHD Atmos down to Dolby Digital | +40 to +300 |
| Hybrid, streaming-service boosts, repacks, internal | +5 to +100 |
| No release group | −500 |
| A tracker's tag on the title (`[TGx]`, `[EZTVx.to]`) | −50 |
| A low-quality encoder (TRaSH's LQ list) | −1000 |
| Banned: upscales, obfuscated names, AV1, x266, disc images, extras, bad dual-audio groups, audio only in a language the show was not made in, an executable at the end of the title | −100000 |

The minimum to be taken at all is −1000, so a low-quality encode can still be the first copy
when it is all there is; anything better replaces it within the week. The language rule is
"not the original language" rather than "not English". Sonarr's **Propers and Repacks** is
set to *Do not prefer*, because otherwise a repack outranks any score. 1080p and 2160p from
every source share one quality tier so that the score decides — **which is what makes Dolby
Vision win every time** — with 720p as a fallback below them; nothing below 720p is ever
taken. Minimum sizes per minute of runtime (2160p web: 15 MB/min) keep a 300 MB "2160p"
from ever being taken.

### A copy as soon as there is one, a better one within the week

The **scout**, in the NAS service, runs every five minutes:

- **As soon as an episode airs** with nothing grabbed, it asks Sonarr to search — every 20
  minutes for six hours, then every two hours, until two days after it aired.
- **For seven days after the first copy**, it asks again every six hours; Sonarr only takes
  a release that beats the queued one by at least 100 points.
- **After the week**, an episode with a finished copy (or already on the NAS) is
  unmonitored, so nothing replaces it again; one without keeps being searched every six
  hours until it has one.
- **A better copy that has finished downloading retires the worse one** from the seedbox,
  unless that one is on its way to the NAS; a season pack stays until every episode in it
  has something better.
- **A download that stops moving** — no progress for three hours, or a magnet whose file
  list never arrives in two — is dropped and marked failed, and Sonarr takes the next.
- **A first copy too slow to be one** — the only copy, still more than four hours from done
  after half an hour — is traded for the next best the same way.

The window, pace and clean-up are settings in `site.env` (`SCOUT_WINDOW_DAYS`,
`SCOUT_UPGRADE_EVERY_HOURS`, `SCOUT_STALL_HOURS`, `SCOUT_REMOVE_SUPERSEDED`,
`SCOUT_FIRST_COPY_MAX_HOURS`); run `deploy.sh` again after changing them.

### It reads qBittorrent the way its window does

Every decision is made from what qBittorrent's own list would say about a torrent —
Downloading, Stalled, Queued, Checking, Stopped, Completed, Missing Files — worked out from
its state, progress and bytes left:

- **Finished** means every byte is there and no check is running. Only a finished copy can
  be brought to the NAS or retire an older one.
- **Stopped with data still to fetch** — what qBittorrent does after a check finds pieces
  missing — is started again; six restarts in an hour means it stops trying and the scout
  replaces the release.
- **Errored or missing its files** is rechecked, then resumed, and replaced only if that
  does not bring it back.
- **Checking, moving or allocating** is never counted as stalled, and the stall clock
  starts again when it is done.

### New episodes only, and nothing moves until you say so

Following a show monitors only the episodes that have not aired yet, so an old episode
turning up in a feed never becomes a download. Unfollowing stops monitoring and deletes
nothing.

An episode waits on the seedbox until you press **Bring to NAS**. Sonarr then copies it —
copies, so the seedbox keeps seeding — into the show's folder with its usual naming. A
better copy that turns up after that waits on the seedbox like any other; press Bring to
NAS again to replace the one on the NAS.

Some NAS setups pause containers while a stream is playing, and a paused container accepts
a connection and never answers. The service checks Sonarr with a three-second timeout and
keeps the seedbox view working meanwhile. When it can see Plex (`PLEX_URL` and
`PLEX_PREFERENCES_FILE` in `site.env`) it says why: "Sonarr is paused while Plex is
streaming".

### Setting it up

1. On the Mac, add `MAGNET_NAS_SSH` and `MAGNET_NAS_DIR` to `local.env`, and copy
   `nas/automatic/site.env.example` to `site.env` (gitignored) with your seedbox, paths and
   service addresses. Sonarr's container has to see the seedbox's download folder (an
   rclone mount, say) at `/seedbox/downloads/` — Bring to NAS copies from there — and
   `PATH_MAP` maps qBittorrent's save path onto it.
2. `nas/automatic/deploy.sh --token` copies the service to the NAS, generates its secrets
   there the first time, starts it, and puts the API token where Magnet reads it
   (`~/Library/Application Support/Magnet/automatic-token`, mode 600).
3. In Magnet, Settings → Automatic: the service's address (a plain-HTTP host also goes in
   `MAGNET_HTTP_HOSTS`, then rebuild Magnet), then **Send Magnet's Sign-In**. It is checked
   against the seedbox once and kept only on the NAS; a refused sign-in is never retried by
   itself.
4. On the NAS, in `MAGNET_NAS_DIR`, run `python3 setup_sonarr.py --plan`, then again
   without `--plan`. It reaches Sonarr at `http://127.0.0.1:8989`; export `SONARR_URL`
   first if yours is elsewhere. It changes nothing until Sonarr can reach the gate, then
   switches everything at once: the Magnet profile (every show Sonarr already monitors that
   is still airing moves to it, so it shows under Following), the gate as the only torrent
   client, Completed Download Handling off (episodes reach the NAS only through Bring to
   NAS), and new episodes only. It is idempotent and snapshots what it changes;
   `python3 rollback_sonarr.py <AUTOMATIC_DATA>/rollback/sonarr-original.json` puts back
   the download clients, Completed Download Handling, Propers and Repacks, size limits, and
   every show's and episode's monitoring and profile. Magnet's formats, profile and gate
   client stay in Sonarr, unused.

## Testing

`tools/tests/run.sh` runs the offline Swift suites — bookmarks, settings, wikipedia, fmhy,
categories, banners, downloads, plugins, choicelog, qbsession, redirects, pagesafety,
blocklists, automatic, qbpane and files — then the Automatic service's Python tests against
in-process fakes, a check that `Mirrors.swift`, where the site probes live, never builds a
bare `URLSession`, and a hygiene check.

- **qbpane** places the qBittorrent pane at every window size and runs its sign-in script in
  a real web view against a local stand-in for qBittorrent (both answer styles, a ban, a
  redirect, and a sign-in that set no session).
- **files** covers the one-time copy of Shuttle's settings, checks that the palette converts
  to the WebUI's colours in light and dark, and checks the orange-under-the-pointer,
  blue-once-chosen rule.
- **Hygiene** scans what is staged, the working copies and new files — Markdown included —
  for home directories, tailnet addresses and NAS volume paths, plus your own identifiers in
  the gitignored `tools/hygiene.local`: one extended regular expression per line, `#` for
  comments; a pattern that does not compile fails the run.

`--live` adds two suites that need network: mirror resolution against a live Wikipedia
article and FMHY's published list, and fetching every search-plugin URL in the catalogue.

## Safety

- **Do not expose the forward proxy to the internet.** It relays TLS for anyone who can reach
  it and has its sign-in, and that sign-in crosses the network unencrypted. A tailnet or LAN
  only.
- **Point the folder on the share at one nothing else manages.**
- **Plain-HTTP hosts need an App Transport Security exception**, listed in
  `MAGNET_HTTP_HOSTS` in `local.env` exactly as the host appears in Settings (subdomains are
  not included), then a rebuild. Without one the request fails before it leaves the process.
- **Keep the Automatic service and the Shuttle relay on a LAN or tailnet.** Both want a
  token, but neither is meant for the internet. Their tokens, the gate password and the
  seedbox sign-in live in files only their owner can read.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with any of the sites this can be pointed at, nor with uBlock Origin,
qBittorrent, Sonarr, Prowlarr, Plex, or FMHY.

---

<p align="center">
  <img src="assets/app-icon.png" alt="The Magnet app icon" width="96">
</p>
