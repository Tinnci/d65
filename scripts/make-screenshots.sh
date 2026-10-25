#!/bin/sh
# Render the Mac app's screens for the README, light and dark, into docs/images/app-*.png.
#
#   scripts/make-screenshots.sh
#
# Uses the Debug build's showcase mode, which draws each window into a PNG from inside the
# process (no screen-recording permission) from the real correction store, session records and
# monitor reads. It never writes a gamma table, so it is safe beside a running D65.
set -eu
cd "$(dirname "$0")/.."
DERIVED=.build/xcode-screens
xcodegen generate >/dev/null
xcodebuild -project D65.xcodeproj -scheme D65Mac -configuration Debug -derivedDataPath "$DERIVED" \
  ${D65_TEAM_ID:+DEVELOPMENT_TEAM="$D65_TEAM_ID" -allowProvisioningUpdates} build >/dev/null
BIN="$DERIVED/Build/Products/Debug/D65Mac.app/Contents/MacOS/D65Mac"
mkdir -p docs/images
for scene in menu prepare place measure review history; do
  for look in light dark; do
    out="docs/images/app-$scene-$look.png"
    "$BIN" --showcase "$scene" --appearance "$look" --output "$out" >/dev/null 2>&1 &
    pid=$!
    i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.25; i=$((i + 1)); done
    kill -9 "$pid" 2>/dev/null || true
    [ -f "$out" ] && echo "$out" || echo "FAILED $out" >&2
  done
done
