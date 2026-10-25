#!/bin/sh
set -eu
revision=$(git -C "$SRCROOT" describe --always --dirty 2>/dev/null || printf 'unknown')
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :D65SoftwareRevision $revision" "$plist"
