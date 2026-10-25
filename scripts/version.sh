#!/bin/sh
# Print D65's version, derived from git. The latest v* tag is the only place a version is written.
#
#   scripts/version.sh            # marketing version, e.g. 0.2.0
#   scripts/version.sh build      # build number: commits reachable from HEAD, e.g. 29
#   scripts/version.sh revision   # exact source revision, e.g. v0.2.0-alpha.1-3-g1a2b3c4-dirty
#   scripts/version.sh tag        # nearest v* tag, e.g. v0.2.0-alpha.1
#
# CFBundleShortVersionString must be numeric, so pre-release suffixes (-alpha.1) are dropped there
# and kept in the revision. Without tags or git, everything falls back to 0.0.0 / 0 / unknown.
set -eu
cd "$(dirname "$0")/.."
tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
case "${1:-marketing}" in
  marketing)
    version=${tag#v}; version=${version%%-*}
    echo "${version:-0.0.0}" ;;
  build) git rev-list --count HEAD 2>/dev/null || echo 0 ;;
  revision) git describe --tags --always --dirty 2>/dev/null || echo unknown ;;
  tag) echo "${tag:-none}" ;;
  *) echo "usage: $0 [marketing|build|revision|tag]" >&2; exit 2 ;;
esac
