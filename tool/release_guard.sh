#!/usr/bin/env bash
# The first thing .github/workflows/release.yml runs, before anything is built
# (#300): does this tag actually describe this tree?
#
# A GitHub release cannot be un-published in any meaningful sense — the tag, the
# assets and their checksums are public the moment the workflow finishes, and
# people's package managers have already seen them. The two ways that goes wrong
# are cheap to detect and impossible to repair afterwards:
#
#   1. `git tag v1.2.3` on a tree whose pubspec says 1.2.2. The RPM, the DEB,
#      the APK versionName and the About dialog would all say 1.2.2 while the
#      release page says 1.2.3.
#   2. Releasing with the AppStream <release> list behind pubspec. GNOME
#      Software and KDE Discover show the NEWEST entry as "what's new", so the
#      new version ships advertising the previous one's notes — forever, in
#      every software centre that has already cached it.
#
# Usage:  tool/release_guard.sh v1.2.3
#
# Pure file reads: no clock, no network, no build. Run it by hand before tagging.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_ID="io.github.illyayalovyy.axiotask"
METAINFO="linux/packaging/${APP_ID}.metainfo.xml"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: tool/release_guard.sh <tag>   (e.g. v1.2.3)"

raw=$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]*#.*$//')
[ -n "$raw" ] || die "could not read version from pubspec.yaml"
VERSION="${raw%%+*}"

case "$TAG" in
  v*) ;;
  *) die "tag '$TAG' is not a release tag — release tags are v<version>, i.e. v${VERSION} for this tree" ;;
esac

TAG_VERSION="${TAG#v}"
[ "$TAG_VERSION" = "$VERSION" ] || die \
  "tag $TAG does not match the pubspec version ${VERSION}. Bump pubspec.yaml (and the metainfo <release> entry) or move the tag — every published asset carries the pubspec version, so a release built from here would advertise ${TAG_VERSION} and install ${VERSION}."

[ -f "$METAINFO" ] || die "AppStream metainfo missing at $METAINFO"
releases=$(grep -oE '<release[[:space:]]+version="[^"]+"' "$METAINFO" \
           | sed -E 's/.*version="([^"]+)".*/\1/')
[ -n "$releases" ] || die "metainfo $METAINFO declares no <release> entry — software centres would show no version at all"

newest=$(printf '%s\n' "$releases" | head -1)
highest=$(printf '%s\n' "$releases" | sort -V | tail -1)

[ "$newest" = "$VERSION" ] || die \
  "metainfo newest <release> is ${newest}, but this tree is ${VERSION} — add (minor/major) or update (patch) the entry in ${METAINFO}, or every software centre will advertise ${newest} for the ${VERSION} release."

[ "$highest" = "$VERSION" ] || die \
  "metainfo declares a <release> for ${highest}, above the released version ${VERSION} — ${METAINFO} advertises a version that was never published."

info "release guard OK — tag $TAG, pubspec $VERSION, metainfo newest <release> $newest"
