<p align="center">
  <img src="assets/app-icon.png" alt="Magnet" width="128">
</p>

<h1 align="center">Magnet</h1>

<p align="center"><b>A browser for torrent sites. A built-in file downloader. New TV episodes, fetched automatically.</b></p>

Magnet is a Mac app for people who download with torrents. It does three things, in one
window:

1. **A browser for torrent sites** — with the ads, fake download buttons and pop-ups
   blocked, and magnet links sent straight to your torrent client.
2. **A built-in file downloader** — brings finished downloads home from your seedbox, and
   handles files a site offers you directly.
3. **Automatic TV** — follow a show, and each new episode is downloaded when it airs.

In the app these are **Manual** (⌘1), **Files** (⌘3) and **Automatic** (⌘2).

A *seedbox* is a rented server that runs your torrent client — Magnet works with
qBittorrent. A *NAS* is the storage box at home where your library lives. The browser
needs neither; the file downloader and automatic TV use both.

## What it does

### 1. A browser for torrent sites (Manual)

- **Ads and fake downloads are blocked.** uBlock Origin's filter lists are built in, and
  ads a site serves itself are caught too.
- **Magnet links go straight to qBittorrent**, and qBittorrent's own window sits in a pane
  beside the browser, so you can watch the torrent arrive.
- **Dead sites keep working.** When a site's address stops answering, Magnet switches to
  one of its mirrors.
- **Pages cannot run off with you.** A page cannot send you to another site or start a
  torrent unless you clicked it, and it never gets to open a new window.
- **Sites load even where they are blocked.** Every page goes through a proxy you run (see
  [What you need](#what-you-need)).

### 2. A built-in file downloader (Files)

- **Files** shows two of your seedbox, your NAS and this Mac side by side, with a transfer
  queue beneath. Send a finished download from the seedbox to the NAS or to this Mac, or
  send files from this Mac up. Copies between the seedbox and the NAS run on the NAS
  itself, so this Mac can sleep.
- **Direct downloads** — files a site hands you itself, rather than through a torrent —
  ask you first. They download to this Mac, then move to a shared folder on your NAS,
  sorted into TV, Games, Books and so on by the kind of site they came from.

### 3. Automatic TV (Automatic)

- **Follow a show** and each new episode is found and downloaded to your seedbox when it
  airs.
- **It searches the same sites you browse** — the ones in the browser's site bar.
- **It never takes a fake, and keeps the best.** A release with a program in it instead of
  a video is refused. Dolby Vision, 4K and HDR are preferred, in that order; a lesser copy
  can be the first one when nothing better exists yet.
- **It keeps looking for a better copy** for a week after the first one is grabbed.
- **Nothing reaches your NAS until you say so:** one click on **Bring to NAS** copies an
  episode into your library.

## What you need

| To use | You need |
|---|---|
| **Anything** | A Mac with Apple silicon, macOS 14 or later, Xcode's command line tools, Python 3 — and a **forward proxy**: a small server that relays your browsing, so sites load even on networks that block them. It must be an HTTPS-tunnelling (`CONNECT`) proxy; `nas/fwd` has one ready to run on a NAS. |
| **Sending magnets** | qBittorrent with its Web UI turned on, usually on your seedbox |
| **Files** | The Shuttle relay running on your NAS |
| **Filing direct downloads on your NAS** | A shared (SMB) folder on it; without one, direct downloads stay on this Mac |
| **Automatic TV** | Sonarr in Docker on your NAS, plus the service in `nas/automatic` — and Prowlarr, if your site bar should decide where Sonarr searches |

Keep all of these on your home network or a tailnet (a private Tailscale network), never
open to the internet.

## Getting started

Before you build, set two things in `local.env`:

- **A bundle id of your own.** Your settings are stored under it, so pick one and keep it.
- **`MAGNET_HTTP_HOSTS`**: the host of every service you reach over plain `http` (usually
  qBittorrent, the Shuttle relay and the automatic TV service) — the host alone, without
  `http://` or a port, exactly as it appears in the address you will type in Settings.
  macOS refuses plain-`http` connections to anything not listed, and changing the list
  needs a rebuild.

```bash
cp local.env.example local.env      # then edit it
./macapp/build.sh --install
```

The first build downloads the ad-block lists, so it needs network and takes a few
minutes. `--install` puts the app in `~/Applications`.

Open it and, in **Settings**, give it your proxy (**Connection**) and a home site
(**Sites**). That is enough for the browser. Each of the other parts has its own
*Set it up* below.

When macOS asks about the Keychain, choose **Always Allow**. Your proxy and qBittorrent
sign-ins share one Keychain item, so it asks once — and once more after each rebuild,
because a build without an Apple Team ID is new to the Keychain every time.

## The browser (Manual)

**The site bar.** Your sites, grouped into **Everything**, **Movies & TV**, **Games**,
**Books** and **Other**, filled from a Firefox bookmark folder, from sites you add, or
both. Drag a chip to move it to another section, or right-click it for **Move to Section**
and to pick one of its addresses by hand. This bar is also where automatic TV searches.

**Magnets.** Click a magnet or `.torrent` link and it goes to qBittorrent — only after a
real click on that link, so a page cannot add torrents on its own. Adding a site to the bar
also installs its search plugin into qBittorrent, so you can search that site from the
client too.

**The qBittorrent pane.** qBittorrent's own interface: beside the browser in a wide window
(1480pt or more), above it in a narrower one. Show or hide it with the sidebar button at
the left of the bar (⌃⌘S). Drag the line between them to resize; double-click it to split
evenly.

**Downloads from a page** ask first — see [Direct downloads](#direct-downloads).

**Getting out.** The open-in-browser button (an arrow leaving a box, next to the route
indicator) hands the page to your normal browser, outside the proxy, for anything Magnet
will not do — a sign-in, a payment page, a download it refuses.

### How the browser protects you

- **One route.** Every page loads through your proxy. If the proxy is down, nothing loads,
  and Magnet says which address failed — it never quietly browses around it. It must be a
  `CONNECT` proxy because a reverse proxy breaks Cloudflare's "verify you are human"
  check, and a `CONNECT` tunnel does not.
- **Blocking.** uBlock Origin's and EasyList's filter lists, converted to the Mac's own
  content blocker — well over 100,000 rules, refreshed when you rebuild and they are over a
  week old. Ads a site serves itself are caught by shape: anything the size of a standard
  ad, or a wide banner image, that links somewhere else. Cloudflare's check is left alone.
  If blocking is *all* you want, a browser running uBlock Origin does more; Magnet is for
  the rest.
- **Leaving your sites.** Following a link off your sites asks once per site, and only
  after a real click; a page redirecting you on its own is simply blocked.
- **Mirrors.** When a site stops answering, Magnet tries its other addresses and switches
  to one that works, then tries the original again at the next launch. Addresses come from
  mirror sets you define in Settings → Mirrors — which can follow a site's Wikipedia
  article — and from FMHY's published list, which is on unless you turn it off there.
- **Cloudflare's check.** While it runs, the page is covered with a "clearing the check"
  note rather than an empty-looking listing, for at most 15 seconds.
- **Your picks stay on this Mac.** Each torrent you send is logged locally
  (`~/.claude/prompt-log/torrent-choices.jsonl`) so Automatic can suggest shows you
  already like. Nothing is sent anywhere.

## The file downloader (Files)

### Files: seedbox, NAS and this Mac

Two file panes over a transfer queue. Each pane shows your seedbox, your NAS or this Mac —
never the same one as the other. Pick files on one side and **Send** (⌘↩) them to the
folder open on the other.

- **Seedbox → NAS** copies run entirely on the NAS, so this Mac can sleep or travel.
- **To or from this Mac**, transfers pass through the app.
- You can also move, replace, delete, make folders (on the NAS and this Mac), bulk-rename
  (on the NAS and this Mac), search either side, keep favorites, check a finished copy's
  file count, and read a transfer's log.
- **Renaming a seedbox item makes a renamed copy.** It copies the item to the folder open in
  the other pane under the new name; the original keeps its name, so it keeps seeding.
- **Deletes on the seedbox or NAS are permanent** (the confirmation says so). On this Mac
  they go to the Trash.
- **Hidden, Files keeps its place** — open folders, history and running transfers — and
  stops checking the relay until you come back.
- **Transfers to or from this Mac run inside the app**, so quitting asks first while one is
  running. NAS transfers carry on regardless.
- **Stopping an upload** to the NAS cuts it off at once; one to the seedbox lets the current
  file finish, so no half-written file is left looking complete.

**Set it up.** Files talks to the **Shuttle relay**, a small service you run on your NAS
that does the copying. Install it from the Shuttle repository (in the same GitHub account
as this one) by following its setup steps, then enter its address and token in
Settings → Files. If you used the standalone Shuttle app, set `MAGNET_SHUTTLE_BUNDLE_ID`
in `local.env` and its settings are copied in once; the relay's token and address are
kept in `~/Library/Application Support/Shuttle/`.

### Direct downloads

Torrent sites start downloads from clicks on anything — fake buttons, the first click
anywhere on the page. So **every direct download asks first**, in a dialog naming the
file, the site it comes from and its size, with **Cancel** as the default. Tick **Always
allow downloads from** that site and it is not asked about again.

- A file from a site unrelated to the page is refused without asking. A file host you
  really use goes in Settings → Downloads, exactly as the refusal names it.
- An approved file downloads to `~/Magnet-Library` and, once complete, moves to the shared
  folder on your NAS, into a folder for the kind of site it came from.
- Give direct downloads a folder of their own on the share; a folder a media server
  imports from will rename files out from under you.

**Set it up.** In Settings → Downloads, give it your NAS's shared (SMB) folder. Its
password comes from your login Keychain — connect to the share once in Finder and let it
remember. Without a share, or while it is unreachable, files stay on this Mac.

## Automatic TV (Automatic)

Automatic TV is built on two free tools you run on your NAS: **Sonarr**, which keeps track
of TV shows and orders each new episode, and **Prowlarr**, which tells Sonarr how to search
each torrent site. Magnet adds a small service beside them (`nas/automatic`) and the
**Automatic** screens in the app.

Follow a show in the **Following** tab. From then on:

1. **When an episode airs,** Magnet asks Sonarr to search the sites in your site bar, and
   keeps asking for two days or until a copy turns up.
2. **The release is checked before it downloads.** Anything with a program in it, no
   episode-size video, or a sample beside an archive is refused, and the next best is tried.
3. **It downloads to your seedbox** and appears in Automatic's **Seedbox** tab (the list of
   episode downloads — not a pane in Files).
4. **For a week after the first copy is grabbed, it looks for better** — Dolby Vision
   first, then 4K, then HDR — and a better copy replaces the worse one on the seedbox.
5. **You press Bring to NAS** when you want it in your library. Sonarr copies it into the
   show's folder; the seedbox keeps seeding.

| Tab | Shows |
|---|---|
| **Following** | Your shows. Search to follow another; right-click one to stop following (nothing is deleted). |
| **Coming Up** | The last three days and next four weeks, and where each episode is. |
| **Seedbox** | Every episode download, what made it good, and **Bring to NAS**. |
| **Blocked** | Releases that were refused or dropped, and why. |
| **Suggestions** | Shows still airing that you picked in the browser or watch in Plex. |

Only new episodes are fetched; following a show never downloads its back catalogue.

### How automatic TV works

- **The gate** is the part of Magnet's service that sits between Sonarr and your real
  qBittorrent. Sonarr sends downloads to it as if it were qBittorrent. It reads each
  release's file list before anything downloads and refuses the bad ones — `.exe` and every
  other way to package a program (`.scr`, `.msi`, `.dmg`, `.iso`, shortcuts, scripts),
  including names disguised with invisible characters. A refused release is blocklisted in
  Sonarr, which tries the next. The gate keeps your qBittorrent sign-in to itself, and
  holds new releases while the seedbox has less than 100 GB free.
- **The scout** is the part that decides when Sonarr searches: every 20 minutes for the
  first six hours after an episode airs, then every two hours until two days after it
  aired. Once a copy is grabbed, it asks every six hours for a week for a better one. A
  download that stops moving for three hours, or a first copy too slow to finish, is
  replaced.
- **Your site bar decides where it searches** (once Prowlarr is set up — see below). The
  sites in the bar are matched to Prowlarr's indexers for them and tagged, and Prowlarr
  gives Sonarr exactly those; if none of them can search for TV, Sonarr keeps every indexer
  it had. Nothing is deleted or disabled, and other apps using Prowlarr keep what they had.
  Settings → Automatic shows what became of each site.
- **What counts as good.** Scores built from [TRaSH Guides](https://github.com/TRaSH-Guides/Guides)'
  formats: Dolby Vision (+10000) outweighs everything else put together, and so does 2160p
  (+3000); HDR (+1000) comes next, though a top release group with the best audio (up to
  +1200) can outscore it. Upscales, obfuscated names, AV1 and audio only in a dubbed
  language are refused; nothing below 720p is taken, and a suspiciously small "4K" is
  ignored.
- **It reads qBittorrent the way its window does.** Only a finished copy (every byte, no
  check running) can be brought home; a torrent that stops after a check is restarted; one
  that errors is rechecked; checking or moving is never mistaken for being stuck.

### Set it up

Before you start: Sonarr running in Docker on the NAS (and Prowlarr, if you want your site
bar to decide where it searches), and your seedbox's download folder mounted into Sonarr's
container at `/seedbox/downloads/` — that is where **Bring to NAS** copies from.

1. In `local.env`, add `MAGNET_NAS_SSH` (your ssh login for the NAS) and `MAGNET_NAS_DIR`
   (the folder on the NAS to install the service into). Copy
   `nas/automatic/site.env.example` to `site.env` and fill in your seedbox, paths and
   services — `PROWLARR_URL` and `PROWLARR_CONFIG_FILE` included, if you use Prowlarr.
2. Run `nas/automatic/deploy.sh --token`. It copies the service to the NAS, starts it, and
   gives Magnet its token.
3. In Magnet, Settings → Automatic: the service's address, then **Send Magnet's Sign-In**,
   which hands the service your qBittorrent sign-in so it can pass downloads on.
4. On the NAS, in that folder: `python3 setup_sonarr.py --plan` to see what it will change,
   then the same without `--plan`. It points Sonarr at the gate (turning off Sonarr's other
   torrent clients and its automatic importing, so episodes reach the NAS only through
   Bring to NAS), sets up the scoring, switches to new episodes only, and moves the shows
   Sonarr already follows that are still airing onto Magnet's profile. It snapshots what it
   changes and prints the snapshot's path; `python3 rollback_sonarr.py <that file>` puts it
   back, leaving Magnet's scoring and gate in Sonarr, unused.

The scout's timings (`SCOUT_*`) are in `site.env`; run `deploy.sh` again after changing
them.

## Keyboard

| Keys | Does |
|---|---|
| ⌘1 / ⌘2 | Manual (the browser) / Automatic |
| ⌘3 | Show or hide Files |
| ⌃⌘S | Show or hide the qBittorrent pane |
| ⌘R | Reload what you are using — the page, Files, Automatic, or qBittorrent when it has the keyboard; on a page still loading, stop it |
| ⌘[ | Back |
| ⇧⌘H | Home |
| ⌘, | Settings |
| ⌃⌘F | Full screen |
| In Files | ⌘↩ send, ⌘↑ up a folder, ⌘⌫ stop a transfer, ⌘F find, ⇧⌘F favorites, ⌘D add a favorite |

Files' keys act only while Files is showing; ⌘↩, ⌘↑ and ⌘⌫ also leave text fields alone.

## Settings

| Tab | For |
|---|---|
| **Sites** | Your home site, the sites in the bar, and a Firefox bookmark folder to fill the bar from |
| **Connection** | The proxy everything goes through — **required** |
| **Torrent Client** | qBittorrent's address and sign-in: magnets, search plugins, the qBittorrent pane |
| **Files** | The Shuttle relay's address and token |
| **Automatic** | The automatic TV service, and which of your sites it can search |
| **Downloads** | The shared folder direct downloads are filed into, and file hosts allowed to send them |
| **Mirrors** | Other addresses for sites that move, and FMHY's list |
| **Appearance** | Page zoom |
| **Blocking** | Filter-list status |

## How it fits together

```
Browser (Manual) ─────▶ your proxy ──▶ torrent sites
   └ magnets ─────────▶ qBittorrent on your seedbox
Files ────────────────▶ Shuttle relay on your NAS ──▶ seedbox / NAS / this Mac
Automatic TV ─────────▶ Magnet's service on your NAS ──▶ Sonarr ──▶ the gate ──▶ qBittorrent
```

## For developers

```
macapp/            the app: SwiftUI and AppKit, built with plain swiftc (no Xcode project)
macapp/shuttle/    Files
nas/fwd/           the forward proxy container
nas/automatic/     the automatic TV service
tools/             the filter-list converter and the tests
```

The filter lists are uBlock Origin's own (uBlock filters, privacy, badware, resource abuse,
quick fixes, unbreak) plus EasyList, EasyPrivacy and Peter Lowe's ad-server list.
`tools/tests/run.sh` runs the Swift test suites, the automatic TV service's Python tests, a
check that site probes go through the proxy, and a hygiene check that keeps personal
hostnames, paths and names out of the repository (your own patterns go in the gitignored
`tools/hygiene.local`). `--live` adds two suites that need network.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with any of the sites this can be pointed at, nor with uBlock Origin,
qBittorrent, Sonarr, Prowlarr, Plex, FMHY or TRaSH Guides.

---

<p align="center">
  <img src="assets/app-icon.png" alt="The Magnet app icon" width="96">
</p>
