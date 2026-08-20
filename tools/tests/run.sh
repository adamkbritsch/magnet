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

run bookmarks  "$(dirname "$0")/bookmarks/main.swift"  "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Bookmarks.swift"
run settings   "$(dirname "$0")/settings/main.swift"   "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift"
run wikipedia  "$(dirname "$0")/wikipedia/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Mirrors.swift"
run fmhy       "$(dirname "$0")/fmhy/main.swift"       "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Mirrors.swift"
run categories "$(dirname "$0")/categories/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift"
run sitestyle  "$(dirname "$0")/sitestyle/main.swift"  "$SRC/SiteStyle.swift"
run render     "$(dirname "$0")/render/main.swift"     "$SRC/SiteStyle.swift"
run banners    "$(dirname "$0")/banners/main.swift"    "$SRC/Domains.swift" "$SRC/Banners.swift"
run downloads  "$(dirname "$0")/downloads/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift" "$SRC/Downloads.swift"
if [ "${1:-}" = "--live" ]; then
  run live "$(dirname "$0")/live/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/SiteStyle.swift" "$SRC/Mirrors.swift"
  run adblock "$(dirname "$0")/adblock/main.swift" "$SRC/SiteStyle.swift"
fi

# Nothing that identifies one person's setup may reach the repository. Checked here
# rather than left to review, because these creep back in one commit at a time.
echo "=============== hygiene ==============="
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATTERNS='britsch|adamkbritsch|dediseedbox|nl4422|100\.101\.182\.68|Plex Server|MediaVolume3'
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
