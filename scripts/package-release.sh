#!/bin/sh
# Build and package a release into dist/: the Mac app, the arm64 CLI, the unsigned iPhone probe IPA,
# and SHA256SUMS.txt.
#
#   scripts/package-release.sh v0.2.0-alpha.2
#
# The tag must point at HEAD; versions are stamped from it (scripts/version.sh). The release
# workflow runs exactly this. With D65_TEAM_ID set the app is signed for that team; otherwise it
# is signed ad hoc. Neither is notarized. The probe IPA is deliberately unsigned: it reads the
# ambient-light sensor through private IOHID calls, so it can't be distributed through Apple, and each
# user re-signs it with their own Apple ID (docs/runbook.md). Unsigned also means it carries no
# provisioning profile, so no team, certificate name or device UDIDs.
set -eu
cd "$(dirname "$0")/.."
tag=${1:?usage: scripts/package-release.sh <tag>}
name=${tag#v}

[ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)" ] || { echo "$tag is not HEAD" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean" >&2; exit 1; }

build=.build/release-package
dist=dist
rm -rf "$build" "$dist"
mkdir -p "$build" "$dist"

if [ -n "${D65_TEAM_ID:-}" ]; then
  signing="DEVELOPMENT_TEAM=$D65_TEAM_ID -allowProvisioningUpdates"
else
  signing="CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="
fi

xcodegen generate >/dev/null
# shellcheck disable=SC2086
xcodebuild -project D65.xcodeproj -scheme D65Mac -configuration Release -derivedDataPath "$build/xcode" \
  $signing build | tail -1
app="$build/xcode/Build/Products/Release/D65Mac.app"
stamped=$(/usr/libexec/PlistBuddy -c "Print :D65SoftwareRevision" "$app/Contents/Info.plist")
[ "$stamped" = "$tag" ] || { echo "app revision is $stamped, expected $tag" >&2; exit 1; }
codesign --verify --deep --strict "$app"

swift build -c release --product d65 >/dev/null
mkdir -p "$build/cli"
cp .build/release/d65 LICENSE THIRD_PARTY_NOTICES.md "$build/cli/"
"$build/cli/d65" selftest >/dev/null

xcodebuild -project D65.xcodeproj -scheme D65Probe -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$build/xcode-ios" CODE_SIGNING_ALLOWED=NO build | tail -1
probe="$build/xcode-ios/Build/Products/Release-iphoneos/D65Probe.app"
stamped=$(/usr/libexec/PlistBuddy -c "Print :D65SoftwareRevision" "$probe/Info.plist")
[ "$stamped" = "$tag" ] || { echo "probe revision is $stamped, expected $tag" >&2; exit 1; }
[ ! -e "$probe/embedded.mobileprovision" ] || { echo "the probe must not carry a provisioning profile" >&2; exit 1; }
mkdir -p "$build/ipa/Payload"
ditto --norsrc --noextattr --noqtn "$probe" "$build/ipa/Payload/D65Probe.app"
(cd "$build/ipa" && zip -q -r -X "../../../$dist/D65Probe-$name-unsigned.ipa" Payload)

# No extended attributes: a plain `unzip` turns them into ._ files that break the app's seal.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$app" "$dist/D65-$name-macOS.zip"
(cd "$build/cli" && zip -q -X "../../../$dist/d65-$name-macos-arm64.zip" d65 LICENSE THIRD_PARTY_NOTICES.md)

# The archive must survive both extraction paths with its signature intact.
for extract in unzip ditto; do
  check="$build/check-$extract"
  mkdir -p "$check"
  if [ $extract = unzip ]; then unzip -q "$dist/D65-$name-macOS.zip" -d "$check"
  else ditto -x -k "$dist/D65-$name-macOS.zip" "$check"; fi
  codesign --verify --deep --strict "$check/D65Mac.app"
done

(cd "$dist" && shasum -a 256 ./*.zip ./*.ipa | sed 's# \./# #' > SHA256SUMS.txt)
cat "$dist/SHA256SUMS.txt"
