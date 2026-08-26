#!/bin/bash
# Test suites for the 1337x app. Offline by default; --live adds the network one.
set -u
SRC="$(cd "$(dirname "$0")/../../macapp" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail=0

run() {
  local name="$1"; shift
  echo "=============== $name ==============="
  if ! swiftc -o "$OUT/$name" "$@" 2>"$OUT/$name.err"; then
    echo "  BUILD FAILED"; sed -n '1,15p' "$OUT/$name.err"; fail=1; return
  fi
  "$OUT/$name" || fail=1
  echo
}

run bookmarks  "$(dirname "$0")/bookmarks/main.swift"  "$SRC/Settings.swift" "$SRC/Bookmarks.swift"
run settings   "$(dirname "$0")/settings/main.swift"   "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift"
run wikipedia  "$(dirname "$0")/wikipedia/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift"
run fmhy       "$(dirname "$0")/fmhy/main.swift"       "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift"
run categories "$(dirname "$0")/categories/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift"
run banners    "$(dirname "$0")/banners/main.swift"    "$SRC/Domains.swift" "$SRC/Banners.swift"
run downloads  "$(dirname "$0")/downloads/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift" "$SRC/Magnet.swift" "$SRC/Downloads.swift"
run plugins    "$(dirname "$0")/plugins/main.swift"    "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Magnet.swift" "$SRC/SearchPlugins.swift"
if [ "${1:-}" = "--live" ]; then
  run live "$(dirname "$0")/live/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Mirrors.swift"
  run plugins-live "$(dirname "$0")/pluginslive/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Magnet.swift" "$SRC/SearchPlugins.swift"
fi

# Every probe that touches a SITE must go through the proxy. A bare URLSession here
# measures a network the app never browses on -- it is what made the app reject its
# own home domain at launch and open a mirror instead. Scoped to Mirrors.swift: the
# torrent client and the plugin catalogue are reached deliberately off-proxy.
# WebKit's compiler is all-or-nothing: one malformed rule fails the whole list, and
# the app swallows it. Half the blocking once vanished this way with no symptom.
run blocklists "$(dirname "$0")/blocklists/main.swift"
echo "=============== proxy discipline ==============="
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BARE="$(grep -nE 'URLSession\.shared|URLSession\(configuration:' "$ROOT/macapp/Mirrors.swift" 2>/dev/null || true)"
if [ -n "$BARE" ]; then
  echo "  FAIL  a site probe bypasses the proxy:"
  echo "$BARE" | sed 's/^/        /'
  fail=1
else
  echo "  PASS  every site probe goes through ProxyRoute"
fi
echo

# Nothing that identifies one person's setup may reach the repository. Checked here
# rather than left to review, because these creep back in one commit at a time.
echo "=============== hygiene ==============="
PATTERNS='britsch|adamkbritsch|dediseedbox|nl4422|100\.101\.182\.68|Plex Server|MediaVolume3|uvu\.edu|b4:0?c:25'
LEAKS="$(cd "$ROOT" && grep -rInE "$PATTERNS" . \
  --exclude-dir=dist --exclude-dir=backup --exclude-dir=.git --exclude-dir=.cache \
  --exclude='local.env' --exclude='seed-local.sh' --exclude='blocklist-*.json' \
  --exclude='*.md' --exclude='run.sh' --exclude='rollback.sh' 2>/dev/null || true)"
if [ -n "$LEAKS" ]; then
  echo "  FAIL  personal values found in files that would be committed:"
  echo "$LEAKS" | sed 's/^/        /'
  fail=1
else
  echo "  PASS  no personal hostnames, usernames or paths in committed sources"
fi
echo

if [ "$fail" -eq 0 ]; then echo "ALL SUITES PASS"; else echo "SUITE FAILURES"; fi
exit $fail
