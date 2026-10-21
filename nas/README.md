# NAS side

Two optional services. Nothing here holds a real value: each has an `.example` file to
copy, and the copies are gitignored.

## `fwd/` — the forward proxy

A tinyproxy container that every request from the browser side goes through (see
"Everything goes through the proxy" in the main README). Copy `tinyproxy.conf.example` to
`tinyproxy.conf`, set its `BasicAuth` line, build the Dockerfile, and publish its port on
your LAN or tailnet only. It allows `CONNECT` to ports 443 and 563 and nothing else.

## `automatic/` — the service behind Automatic mode

One small container (Python standard library, no image to build) with two jobs:

- **the gate** on `172.17.0.1:8791`, reachable only from other containers: Sonarr's
  download client, standing in front of the seedbox's qBittorrent, holding every torrent
  until its file list has been read;
- **the API** on `:8790`, token required: what Magnet's Automatic mode shows and does,
  and where Magnet sends its list of sites.

| File | What it is |
|---|---|
| `app/automatic/` | The service: `gate.py`, `rules.py` (what a release may contain), `scout.py` (first copy fast, a better one within the week), `api.py`, `sources.py` (sites to Prowlarr indexers), `qbit.py`, `sonarr.py`, `store.py` |
| `formats/` | TRaSH Guides' Sonarr custom formats (MIT), vendored; the scores are in `setup_sonarr.py` |
| `tests/` | `python3 -m unittest` against in-process fakes of qBittorrent, Sonarr and Prowlarr |
| `docker-compose.yml` | Every machine-specific value comes from `.env` |
| `site.env.example` | Copy to `site.env` (gitignored): your seedbox, paths and service addresses |
| `deploy.sh` | Run from the Mac: copies the service, turns `site.env` into `.env` plus generated secrets, starts it; `--token` gives Magnet the API token |
| `setup_sonarr.py` | Points Sonarr at the gate, adds the Magnet profile, monitors new episodes only. `--plan` first. All or nothing, and keeps the pre-setup state as `rollback/sonarr-original.json` |
| `rollback_sonarr.py` | Undoes `setup_sonarr.py` from its snapshot |

Run the tests with:

```bash
cd nas/automatic && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=app:tests python3 -m unittest discover -s tests -v
```
