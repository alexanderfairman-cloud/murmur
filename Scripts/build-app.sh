#!/bin/bash
# Builds build/Murmur.app.   Run from anywhere:   Scripts/build-app.sh
# Signing: if the "Murmur Local Signing" certificate exists (Scripts/make-signing-cert.sh makes it), every build is
# signed with it and macOS keeps Murmur's permissions across rebuilds. Without it the app is signed "ad hoc",
# which macOS treats as a brand new app after every rebuild, so permissions must be switched off and on again.
# Set SIGN_IDENTITY to use a different certificate.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain-fix.sh

if [ -z "${SIGN_IDENTITY:-}" ]; then
  if security find-identity -p codesigning | grep -q "Murmur Local Signing"; then
    SIGN_IDENTITY="Murmur Local Signing"
  else
    SIGN_IDENTITY="-"
    echo "Note: no signing certificate, so this build is signed ad hoc (permissions reset on every rebuild)."
  fi
fi

swift build -c release --product Murmur
BIN="$(swift build -c release --show-bin-path)"
APP="build/Murmur.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Resource bundles shipped by Swift packages. Dictation does not use them, but a missing one crashes on load.
for bundle in "$BIN"/*.bundle; do
  if [ -e "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done

# The Dock icon is drawn by the app itself (same dark pill and waveform as the floating bar), so it never goes stale.
ICONSET="$(mktemp -d)/Murmur.iconset"
"$BIN/Murmur" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Murmur.icns"
rm -rf "$(dirname "$ICONSET")"

codesign --force --sign "$SIGN_IDENTITY" --identifier com.jamesseriph.murmur "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"
