#!/bin/sh
# Xcode build phase: stamp version, build number and source revision from git into the built
# Info.plist. Runs before code signing, so the signature covers the stamped values.
set -eu
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
version="$SRCROOT/scripts/version.sh"
set_key() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"
}
set_key CFBundleShortVersionString "$(sh "$version" marketing)"
set_key CFBundleVersion "$(sh "$version" build)"
set_key D65SoftwareRevision "$(sh "$version" revision)"
