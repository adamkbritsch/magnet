#!/bin/bash
# Build "Magnet.app" — native SwiftUI + WKWebView, with the Firefox
# bookmark bar, uBlock-derived content blocking, NAS forward-proxy routing, and
# native magnet handoff to qBittorrent.
#
#   ./build.sh              build into dist/
#   ./build.sh --install    build, then install to ~/Applications
set -euo pipefail

ROOT="${MAGNET_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Machine-specific settings, if any. Gitignored -- see local.env.example. This is
# sourced BEFORE the defaults below so it can override every one of them.
if [[ -f "$ROOT/local.env" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$ROOT/local.env"; set +a
fi

SRC="$ROOT/macapp"
DIST="$ROOT/dist"
APP="$DIST/Magnet.app"
INSTALLED="${MAGNET_INSTALL_PATH:-$HOME/Applications/Magnet.app}"
# The bundle id is also the UserDefaults domain and the basis of the Keychain
# service names, so pick one in local.env and keep it: changing it later orphans
# every setting, every saved credential and every macOS permission grant.
BUNDLE_ID="${MAGNET_BUNDLE_ID:-com.example.magnet}"
EXEC_NAME="Magnet"
VERSION="1.0.0"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$SRC/blocklist-0.json" ]]; then
  echo "==> No filter lists found; building them"
  python3 "$ROOT/tools/build-blocklist.py"
fi

# Build against Xcode's SDK, not the Command Line Tools' one. Shared verbatim with
# the sibling apps (Shuttle and qBittorrent).
#
# `xcode-select -p` points at CommandLineTools here, so a bare `swiftc` links against
# SDK 15.5 and the binary records `sdk 15.5`. On macOS 26 the LINKED SDK version is
# what decides whether AppKit hands you the current control shapes AND the current
# window corner radius -- measured: sdk 15.5 gives a 12.5pt corner, sdk 26.5 gives
# 23pt. There is no public API to set it; the SDK is the only lever.
#
# The -Xlinker -platform_version line is NOT optional: without it the binary records
# `sdk 14.0` and the whole exercise is a no-op. Xcode passes it automatically; a
# hand-rolled swiftc does not.
#
# Deployment target and linked SDK are independent: LSMinimumSystemVersion stays at
# 14.0 and the sources still compile at -target arm64-apple-macosx14.0.
DEVDIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVDIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVDIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ -x "$SWIFTC" && -d "$SDK" ]]; then
  SDKVER="$(/usr/bin/plutil -extract Version raw "$SDK/SDKSettings.plist" 2>/dev/null || echo "")"
  if [[ -n "$SDKVER" ]]; then
    SDKARGS=(-sdk "$SDK" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDKVER")
    echo "==> Using Xcode SDK $SDKVER"
  else
    SDKARGS=(-sdk "$SDK")
  fi
else
  echo "==> Xcode not found; using CLT swiftc (pre-Tahoe appearance)"
  SWIFTC=swiftc; SDKARGS=()
fi

# The filter lists are generated, not checked in -- 16 MB of derived JSON does not
# belong in git, and a committed copy is stale the day after it lands. Failing here is
# not fatal: the app reports "No filter lists bundled" and browses unprotected.
if ! compgen -G "$SRC/blocklist-*.json" >/dev/null; then
  echo "==> Building filter lists (first run; a few minutes)"
  if command -v python3 >/dev/null && [[ -f "$ROOT/tools/build-blocklist.py" ]]; then
    python3 "$ROOT/tools/build-blocklist.py" 2>&1 | sed 's/^/    /' || \
      echo "    could not build them; the app will run without content blocking"
  else
    echo "    python3 or tools/build-blocklist.py missing; skipping"
  fi
fi

echo "==> Compiling"
"$SWIFTC" -target arm64-apple-macosx14.0 -O "${SDKARGS[@]}" \
  "$SRC"/main.swift "$SRC"/Theme.swift "$SRC"/Domains.swift "$SRC"/Settings.swift "$SRC"/Routes.swift \
  "$SRC"/Bookmarks.swift "$SRC"/Magnet.swift "$SRC"/SearchPlugins.swift "$SRC"/Mirrors.swift "$SRC"/Categories.swift "$SRC"/SiteStyle.swift "$SRC"/Banners.swift \
  "$SRC"/Downloads.swift \
  "$SRC"/WebView.swift "$SRC"/RootView.swift \
  -framework AppKit -framework SwiftUI -framework WebKit \
  -framework Network -framework Security \
  -lsqlite3 \
  -o "$TMP/$EXEC_NAME"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
# Icon. Magnet.icon is an Icon Composer bundle, which iconutil cannot read -- it needs
# actool, and actool must be passed the .icon DIRECTLY: wrapping it in an
# Assets.xcassets makes it silently produce nothing. This yields both Assets.car (the
# artwork macOS 26 uses via CFBundleIconName) and a legacy .icns fallback.
ICON_KEYS=""
DEVDIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -d "$SRC/Magnet.icon" && -x /usr/bin/actool && -d "$DEVDIR" ]]; then
  echo "==> Compiling icon (actool)"
  if DEVELOPER_DIR="$DEVDIR" /usr/bin/actool "$SRC/Magnet.icon" \
       --compile "$APP/Contents/Resources" \
       --platform macosx --minimum-deployment-target 14.0 \
       --app-icon Magnet \
       --output-partial-info-plist "$TMP/icon.plist" >/dev/null 2>&1 \
     && [[ -f "$APP/Contents/Resources/Magnet.icns" ]]; then
    ICON_KEYS="  <key>CFBundleIconFile</key><string>Magnet</string>
  <key>CFBundleIconName</key><string>Magnet</string>"
    echo "    Assets.car + Magnet.icns"
  else
    echo "    actool produced nothing; falling back"
  fi
fi
if [[ -z "$ICON_KEYS" && -f "$SRC/app.icns" ]]; then
  cp "$SRC/app.icns" "$APP/Contents/Resources/app.icns"
  ICON_KEYS="  <key>CFBundleIconFile</key><string>app.icns</string>"
fi
compgen -G "$SRC/blocklist-*.json" >/dev/null && cp "$SRC"/blocklist-*.json "$APP/Contents/Resources/" || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A host reached over plain HTTP needs an App Transport Security exception or the
# request fails with -1022 before it leaves the process. Scoped per host rather than
# switching ATS off wholesale, and empty by default -- someone whose services are all
# HTTPS needs none of this.
#
# Deliberately NOT NSAllowsLocalNetworking: it cancels NSAllowsArbitraryLoads and does
# not cover tailnet addresses, which is exactly the case this exists for.
ATS_KEYS=""
if [[ -n "${MAGNET_HTTP_HOSTS:-}" ]]; then
  ATS_ENTRIES=""
  IFS=',' read -r -a _hosts <<< "$MAGNET_HTTP_HOSTS"
  for h in "${_hosts[@]}"; do
    h="$(echo "$h" | tr -d '[:space:]')"
    [[ -z "$h" ]] && continue
    ATS_ENTRIES+="
      <key>${h}</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSIncludesSubdomains</key><false/>
      </dict>"
  done
  if [[ -n "$ATS_ENTRIES" ]]; then
    ATS_KEYS="  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>${ATS_ENTRIES}
    </dict>
  </dict>"
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Magnet</string>
  <key>CFBundleDisplayName</key><string>Magnet</string>
  <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
${ICON_KEYS}
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
${ATS_KEYS}
</dict></plist>
PLIST

# Sign with a STABLE self-signed identity, creating it on first use.
#
# This is not cosmetic. An ad-hoc signature's designated requirement is cdhash-based:
#     designated => cdhash H"ee122f41..."
# i.e. bound to the binary's hash, so EVERY rebuild is a different code identity.
# TCC, the Local Network permission and Keychain ACLs all key on exactly that, which
# is why every single update made macOS treat this as a brand-new app and re-ask for
# every permission it had already been granted.
#
# A self-signed certificate binds it to the cert instead:
#     designated => identifier "com.example.x1337" and certificate leaf = H"..."
# which is stable across every future build. One prompt, ever.
#
# codesign does NOT require the certificate to be TRUSTED in order to sign with it,
# so no admin rights and no trust-settings prompt are needed -- `security
# find-identity -p codesigning` will still report "0 valid identities", which is
# expected and harmless. Same approach the Shuttle build uses.
SIGN_ID="${MAGNET_SIGN_IDENTITY:-1337x Local Signing}"

if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "==> Creating a stable signing identity: $SIGN_ID"
  CERTDIR="$(mktemp -d)"
  if openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
        -subj "/CN=$SIGN_ID" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 \
     && openssl pkcs12 -export -legacy -out "$CERTDIR/id.p12" \
        -inkey "$CERTDIR/key.pem" -in "$CERTDIR/cert.pem" \
        -passout pass:x1337 -name "$SIGN_ID" >/dev/null 2>&1 \
     && security import "$CERTDIR/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P x1337 -A >/dev/null 2>&1; then
    echo "    created"
  else
    echo "    could not create one; falling back to ad-hoc"
  fi
  # The private key lives in the Keychain now; do not leave a copy on disk.
  rm -rf "$CERTDIR"
fi

if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "==> Signing as \"$SIGN_ID\""
  codesign --force --sign "$SIGN_ID" "$APP" 2>&1 | sed 's/^/    /' || true
else
  echo "==> Signing (ad-hoc -- expect permission prompts after every rebuild)"
  codesign --force --sign - "$APP" 2>&1 | sed 's/^/    /' || true
fi

echo "==> Built: $APP"
echo "    filter lists: $(ls "$APP/Contents/Resources"/blocklist-*.json 2>/dev/null | wc -l | tr -d ' ')"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to $INSTALLED"
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  # Exactly one launchable bundle, or the Dock is free to open whichever it likes.
  #
  # Two bundles sharing one id is the documented trap, and leaving the build output
  # behind is how you get one: the Dock ends up aimed at dist/, `quit` closes only
  # that copy, and a rebuild overwrites the FILE while the running process keeps the
  # inode it opened -- so every rebuild appears to do nothing, with no error anywhere.
  # Cost me an hour of "relaunch to pick it up" that could not have worked.
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  rm -rf "$APP"
  "$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true
  echo "==> Installed (build output removed, so only one bundle can be launched)"
fi
