#!/bin/bash
# Builds and signs LiveDrive.app and puts it in ~/Applications (live-drive-desktop, macOS).
# install.sh normally calls it; it also creates the signing certificate.
#
#   build.sh            builds when the source changed; otherwise leaves the app alone
#   build.sh --force    builds anyway
#   build.sh --adhoc    ad-hoc signature, no certificate (both permissions are granted again after every build)
#
# Unchanged source is not rebuilt because of TCC: a grant is tied to the bundle id AND the signature.
# An ad-hoc signature is the cdhash, so every build drops the grants. With a self-signed certificate
# the requirement is the certificate's fingerprint and grants survive a rebuild (docs/decisions.md).
# LIVEDRIVE_SIGN_ID changes the certificate name.
#
# macOS runs this with /bin/bash 3.2: no bash 4+ syntax.

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/LiveDrive.app"
STAMP="$HOME/.cache/live-drive.build"
SIGN_ID="${LIVEDRIVE_SIGN_ID:-live-drive-codesign}"
BUNDLE_ID=io.github.smlblr.LiveDrive

force=0
adhoc=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --adhoc) adhoc=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "LiveDrive is macOS only" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "no swiftc: xcode-select --install" >&2; exit 1; }

# No -v: the certificate install.sh creates is not marked trusted (CSSMERR_TP_NOT_TRUSTED),
# so -v does not list it, but codesign signs with it.
if [ "$adhoc" = 1 ]; then
  SIGN_ID="-"
elif ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  echo "no \"$SIGN_ID\" signing identity (security find-identity -p codesigning)." >&2
  echo "install.sh creates the certificate; or build with --adhoc." >&2
  exit 1
fi

# Stamp: source + signing identity. It lives outside the bundle: writing into a signed bundle breaks the signature.
sum="$(cat "$SRC/LiveDrive.swift" "$SRC/icon.swift" "$SRC/Info.plist" "$SRC/build.sh" | shasum -a 256 | cut -d' ' -f1)-$SIGN_ID"
if [ "$force" = 0 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$sum" ] \
   && codesign --verify "$APP" 2>/dev/null; then
  echo "LiveDrive.app is up to date: $APP"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/LiveDrive.app/Contents/MacOS" "$tmp/LiveDrive.app/Contents/Resources"
cp "$SRC/Info.plist" "$tmp/LiveDrive.app/Contents/Info.plist"
swift "$SRC/icon.swift" "$tmp/LiveDrive.iconset" \
  && iconutil -c icns -o "$tmp/LiveDrive.app/Contents/Resources/LiveDrive.icns" "$tmp/LiveDrive.iconset" \
  || echo "could not draw the icon; LiveDrive.app gets the generic one" >&2
# Swift 5 language mode: global state (step thread ↔ main thread) is guarded by one NSLock;
# Swift 6's strict concurrency checking would reject it at compile time.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit \
  -o "$tmp/LiveDrive.app/Contents/MacOS/LiveDrive" "$SRC/LiveDrive.swift" || exit 1
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$tmp/LiveDrive.app" || exit 1

mkdir -p "$HOME/Applications" "$HOME/.cache"
rm -rf "$APP"
mv "$tmp/LiveDrive.app" "$APP"
echo "$sum" > "$STAMP"
echo "LiveDrive.app installed: $APP (signed: $SIGN_ID)"
