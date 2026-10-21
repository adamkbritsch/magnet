#!/bin/bash
# Test suites for Magnet. Offline by default; --live adds the network ones.
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
run settings   "$(dirname "$0")/settings/main.swift"   "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift"
run wikipedia  "$(dirname "$0")/wikipedia/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift"
run fmhy       "$(dirname "$0")/fmhy/main.swift"       "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift"
run categories "$(dirname "$0")/categories/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift"
run banners    "$(dirname "$0")/banners/main.swift"    "$SRC/Domains.swift" "$SRC/Banners.swift"
run downloads  "$(dirname "$0")/downloads/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift" "$SRC/Magnet.swift" "$SRC/Downloads.swift"
run plugins    "$(dirname "$0")/plugins/main.swift"    "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Magnet.swift" "$SRC/SearchPlugins.swift"
if [ "${1:-}" = "--live" ]; then
  run live "$(dirname "$0")/live/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Mirrors.swift"
  run plugins-live "$(dirname "$0")/pluginslive/main.swift" "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Magnet.swift" "$SRC/SearchPlugins.swift"
fi

# Every probe that touches a SITE must go through the proxy. A bare URLSession here
# measures a network the app never browses on -- it is what made the app reject its
# own home domain at launch and open a mirror instead. Scoped to Mirrors.swift: the
# torrent client and the plugin catalogue are reached deliberately off-proxy.
# WebKit's compiler is all-or-nothing: one malformed rule fails the whole list, and
# the app swallows it. Half the blocking once vanished this way with no symptom.
run choicelog  "$(dirname "$0")/choicelog/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Magnet.swift"
run qbsession  "$(dirname "$0")/qbsession/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Magnet.swift"
run redirects  "$(dirname "$0")/redirects/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Magnet.swift" "$SRC/Mirrors.swift" "$SRC/Routes.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift" "$SRC/Downloads.swift"
run pagesafety "$(dirname "$0")/pagesafety/main.swift" "$SRC/Domains.swift" "$SRC/Banners.swift"
run blocklists "$(dirname "$0")/blocklists/main.swift"
run automatic  "$(dirname "$0")/automatic/main.swift"  "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Routes.swift" "$SRC/Mirrors.swift" "$SRC/Categories.swift" "$SRC/Bookmarks.swift" "$SRC/Magnet.swift" "$SRC/SearchPlugins.swift" "$SRC/Automatic.swift"
run qbpane     "$(dirname "$0")/qbpane/main.swift"     "$SRC/Domains.swift" "$SRC/Settings.swift" "$SRC/Secrets.swift" "$SRC/Magnet.swift" "$SRC/Theme.swift" "$SRC/PaneSplit.swift" "$SRC/QBittorrentPane.swift"
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

# The NAS service behind Automatic mode: the gate's file rules, the qBittorrent and
# Sonarr conversations, and the sites-to-sources sync, against in-process fakes.
echo "=============== automatic (NAS service, python) ==============="
if command -v python3 >/dev/null 2>&1; then
  PYOUT="$(cd "$ROOT/nas/automatic" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=app:tests \
           python3 -m unittest discover -s tests 2>&1)"
  if [ $? -eq 0 ]; then
    echo "  PASS  $(echo "$PYOUT" | grep -E '^Ran [0-9]+ tests' | head -1)"
  else
    echo "  FAIL"; echo "$PYOUT" | tail -40 | sed 's/^/        /'; fail=1
  fi
else
  echo "  SKIP  python3 not found"
fi
echo

# Nothing that identifies one person's setup may reach the repository. Checked here
# rather than left to review, because these creep back in one commit at a time.
#
# The patterns that name a real setup cannot live in this file: it is published, so
# listing them here would publish them. They go in tools/hygiene.local (gitignored),
# one extended regex per line; what is here is only what is wrong for anyone -- a home
# directory, a tailnet address or name, a NAS volume path.
#
# Three things are scanned: what is staged (that is what the next commit holds, even
# if the file has been tidied since), the working copies of tracked files, and new
# files not ignored. Case is ignored; LICENSE is exempt because it names its author.
# It fails closed: a git or grep error, or a pattern that does not compile, is a FAIL,
# never a quiet PASS. No \b anywhere -- git grep on macOS does not support it, and a
# pattern that silently matches nothing is worse than none.
echo "=============== hygiene ==============="
B='(^|[^A-Za-z0-9._-])'                       # where a path or address can start
E='([^A-Za-z0-9._-]|$)'                       # and end
GENERIC="$B\\\\?/(Users|home)\\\\?/[A-Za-z0-9._-]+|$B/volume[0-9]+$E|(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)|[A-Za-z0-9-]\.ts\.net$E"

hygiene_scan() {   # hygiene_scan <repo dir> <patterns>; prints leaks; 0 clean, 1 leaks, 2 error
  local dir="$1" pats="$2" out rc st=0
  local ex=(-- . ':!LICENSE')
  out="$(cd "$dir" && git grep --cached -IniE "$pats" "${ex[@]}")"; rc=$?
  [ $rc -gt 1 ] && return 2; [ -n "$out" ] && { echo "$out" | sed 's/^/staged: /'; st=1; }
  out="$(cd "$dir" && git grep -IniE "$pats" "${ex[@]}")"; rc=$?
  [ $rc -gt 1 ] && return 2; [ -n "$out" ] && { echo "$out"; st=1; }
  out="$(cd "$dir" && git ls-files -z -o --exclude-standard "${ex[@]}" | xargs -0 grep -IniE "$pats" --)"; rc=$?
  [ $rc -gt 1 ] && [ $rc -ne 123 ] && return 2; [ -n "$out" ] && { echo "$out"; st=1; }
  return $st
}

PATTERNS="$GENERIC"
LOCAL="$ROOT/tools/hygiene.local"
if [ -f "$LOCAL" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    if printf '' | grep -qE -- "$line" 2>/dev/null; [ $? -eq 2 ]; then
      echo "  FAIL  tools/hygiene.local has a pattern that does not compile: $line"; fail=1; continue
    fi
    PATTERNS="$PATTERNS|$line"
  done < "$LOCAL"
else
  echo "  note  no tools/hygiene.local, so only the generic patterns are checked"
fi

# Self-test first: a scan that cannot find a planted leak proves nothing.
CANARY="$(mktemp -d)"
# Assembled at run time, so this file never contains a leak of its own.
( cd "$CANARY" && git init -q && printf 'ip 100.%s\nhost box.tail1%s\nHOME=%s/someone\n' '101.9.9' '.ts.net' '/Users' > leak.txt \
  && git add leak.txt ) >/dev/null 2>&1
CAUGHT="$(hygiene_scan "$CANARY" "$GENERIC" | grep -c 'staged:')"
rm -rf "$CANARY"
if [ "$CAUGHT" -lt 3 ]; then
  echo "  FAIL  the scan found $CAUGHT of 3 planted leaks; it cannot be trusted on this machine"; fail=1
fi

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "  FAIL  not a git work tree, so nothing can be checked"; fail=1
else
  LEAKS="$(hygiene_scan "$ROOT" "$PATTERNS")"; rc=$?
  if [ $rc -eq 2 ]; then
    echo "  FAIL  the scan itself failed (git or grep error), so nothing is known"; fail=1
  elif [ $rc -eq 1 ]; then
    echo "  FAIL  personal values found in what would be committed:"
    echo "$LEAKS" | sort -u | sed 's/^/        /'
    fail=1
  else
    echo "  PASS  no personal hostnames, usernames or paths in what would be committed (self-test: $CAUGHT/3)"
  fi
fi
echo

if [ "$fail" -eq 0 ]; then echo "ALL SUITES PASS"; else echo "SUITE FAILURES"; fi
exit $fail
