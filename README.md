# Magnet

A native macOS browser for torrent sites: a real SwiftUI window around `WKWebView`,
with a bookmark bar grouped by what each site is for, uBlock-derived content
blocking, automatic fallback to a site's other domains, magnet handoff to a torrent
client, and direct downloads filed into an archive on a NAS.

It ships with **nothing configured** — no sites, no home page, no services. Everything
is set up in Settings.

---

## Setup

```bash
cp local.env.example local.env      # optional; see below
./macapp/build.sh --install         # builds, signs, installs to ~/Applications
```

First launch shows a setup screen. At minimum, set a **home site** under
Settings → Sites. Everything else is optional:

| Tab | What it is for |
|---|---|
| **Sites** | The home site, sites in the bar, and optionally a Firefox bookmark folder to mirror |
| **Connection** | Direct or through your own forward proxy |
| **Torrent Client** | A qBittorrent Web API endpoint for magnet links |
| **Downloads** | An SMB share to file direct downloads into |
| **Mirrors** | Fallback domains for sites that move |
| **Blocking** | Filter list status |

### `local.env`

Build-time settings, gitignored:

- `MAGNET_BUNDLE_ID` — reverse-DNS id. **Also the UserDefaults domain and the basis of
  the Keychain service names**, so pick one and keep it; changing it later orphans
  every setting, credential and permission grant.
- `MAGNET_SIGN_IDENTITY` — name of a self-signed code-signing certificate, created on
  first build. See *Signing* below.
- `MAGNET_HTTP_HOSTS` — comma-separated hosts you reach over plain HTTP. Each gets an
  App Transport Security exception; without one, requests fail with `-1022` before
  leaving the process. Leave empty if everything is HTTPS.

---

## Why a *forward* proxy, not a reverse proxy

If you route the browser through a proxy to reach a Cloudflare-protected site, it
**must** be a forward (HTTP `CONNECT`) proxy. Measured:

| Path | Result |
|---|---|
| `curl` direct | 403 challenge |
| `WKWebView` direct | solved in ~6s |
| `WKWebView` through a Caddy **reverse** proxy | never solved, stuck 30s+ |
| `WKWebView` through an HTTP **CONNECT** proxy | solved in ~6s, same as direct |

A reverse proxy terminates TLS and rewrites the origin, so the challenge cannot
validate. `CONNECT` tunnels raw TLS to the origin, so Cloudflare sees an ordinary
browser. Wired up with `WKWebsiteDataStore.proxyConfigurations` and
`ProxyConfiguration(httpCONNECTProxy:)`.

A corollary worth knowing: Cloudflare Tunnel carries HTTP services but **not** CONNECT
proxies, so remote access to such a proxy needs a VPN or tailnet.

`nas/` has a tinyproxy container for the proxy side.

## Domain fallback

Sites move, and sometimes vanish for a day. When a navigation fails at the transport
layer the app probes the site's other domains, switches to one that answers, and
remembers the choice — re-checking later so it returns home when the site recovers.

Only transport failures count. **An HTTP-level rejection — a Cloudflare 403 above all
— proves the domain is alive**, so it never triggers a switch.

Domain lists come from mirror sets you define in Settings. A set can name a Wikipedia
article, in which case its domain list is re-read from that article's infobox, which
is how a site that rotates domains keeps working without an update. Optionally, FMHY's
published list adds mirrors for hundreds of sites in bulk; your own sets always win.

## Downloads

Any site in the bar is a download source, so adding a bookmark is all it takes.
Captured files land on the Mac first and move to the share once whole — a download
writes incrementally, and doing that over SMB is slow and leaves half-written files
when the link drops.

Where a file goes is decided by **what the site is**, using the same categories that
group the bar; the file extension only breaks the tie for a site covering several
types. Point the archive root at a folder nothing else manages: if it is somewhere a
media pipeline watches, captured files get imported, renamed and moved out from under
you.

## Ad blocking

`WKWebView` cannot load a browser extension, but WebKit ships the same engine Safari
content blockers use. `tools/build-blocklist.py` converts uBlock Origin's own lists
into a `WKContentRuleList` — around 141,000 rules. They are generated on first build
rather than committed.

Three things that cost a debugging cycle each:

- **WebKit's regex is a PCRE subset, and one bad rule fails the whole list.** No `\w`
  or `\d`, no `{n,m}`, no `(a|b)`, ASCII only.
- **`ignore-previous-rules` only cancels within the same compiled list**, so when
  splitting into chunks, every block chunk must carry the full exception set or sites
  silently over-block.
- uBO's cosmetic filters (`#@#`, `#?#`, `#@?#`, `#$#`) must be stripped before the
  network parser sees them.

### The "blank listings" symptom

During Cloudflare's ~6s check, a site serves its own shell with zero rows, which looks
like the blocker broke it. It hasn't: measured with filters on and off after settling,
the results are identical. The app covers the view with a "clearing the check" state,
capped at 15s so a stalled challenge still becomes clickable. Diagnose anything in this
class by A/B-ing rule lists **and waiting for render** — an early probe lies.

## Signing

The build creates a self-signed certificate on first run and signs with it. This is
not cosmetic: an ad-hoc signature's designated requirement is bound to the binary's
hash, so every rebuild is a different code identity and macOS re-asks for every
permission, every time. A certificate makes the requirement stable:

```
designated => identifier "com.example.magnet" and certificate leaf = H"..."
```

`codesign` does not require the certificate to be *trusted*, so no admin rights are
needed — `security find-identity -v -p codesigning` still reporting "0 valid
identities" is expected and harmless.

When macOS asks for a Keychain password, choose **Always Allow**. "Allow" is one-shot
and asks again forever.

## Tests

```bash
./tools/tests/run.sh          # offline
./tools/tests/run.sh --live   # adds network checks
```

Suites cover bookmark persistence, settings defaults and round-tripping, the Wikipedia
and FMHY mirror parsers against captured fixtures, categorisation, download filing, and
a hygiene check that no machine-specific values have crept into committed sources.

## Layout

```
macapp/     the app: one file per concern, built by build.sh with swiftc
nas/        tinyproxy container for the forward proxy
tools/      blocklist converter, test suites, fixtures
```

There is no Xcode project. `build.sh` compiles an explicit list of sources — a new
`.swift` file must be added to it or it fails with "cannot find X in scope".

## Licence

MIT. See `LICENSE`.

The app is a browser; what you do with it is your business and your responsibility.
