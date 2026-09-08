#!/usr/bin/env bash
# Build an installable .deb of the axiotask Linux desktop app (#300).
#
# The Debian/Ubuntu twin of tool/build_rpm.sh: it installs the SAME tree at the
# SAME paths, so the two packages are the same application. Needs `dpkg-deb`
# (Fedora: `sudo dnf install dpkg`; Debian/Ubuntu: part of the base system).
# test/packaging/deb_packaging_test.dart reads the RPM's %files list and demands
# every path of it from the package this script builds — that cross-check is
# what keeps the two distributions from drifting into different apps.
#
# Layout the package installs (identical to the RPM's):
#   /usr/lib/axiotask/                 the whole release bundle (binary, data, lib)
#   /usr/bin/axiotask                  symlink -> ../lib/axiotask/axiotask
#   /usr/share/applications/io.github.illyayalovyy.axiotask.desktop
#   /usr/share/icons/hicolor/<size>/apps/axiotask.png   (16..512 + scalable SVG)
#   /usr/share/metainfo/io.github.illyayalovyy.axiotask.metainfo.xml (AppStream)
# plus what Debian requires of every package and the RPM does not:
#   /usr/share/doc/axiotask/copyright, changelog.Debian.gz
#   /usr/share/lintian/overrides/axiotask
#
# Usage:
#   tool/build_deb.sh                  build the .deb (needs flutter + dpkg-deb)
#   tool/build_deb.sh --dry-run        validate config + render control + report
#                                      the exact dpkg-deb command, WITHOUT
#                                      building (never invokes dpkg-deb; always
#                                      exits 0 on a valid config)
#   tool/build_deb.sh --print-control  render DEBIAN/control to stdout and exit
#   tool/build_deb.sh --stage DIR      stage the package root into DIR and exit
#   tool/build_deb.sh --bundle DIR     use an already-built release bundle
#   tool/build_deb.sh --out DIR        write the .deb into DIR (default: dist/)
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG_NAME="axiotask"
SUMMARY="Fast, offline-first Google Tasks client"
MAINTAINER="Illya Yalovyy <yalovoy@gmail.com>"
URL="https://github.com/IllyaYalovyy/axiotask"
# The ONE application id (#227) — see tool/build_rpm.sh for why the desktop
# entry MUST be installed under it.
APP_ID="io.github.illyayalovyy.axiotask"
DESKTOP_SRC="linux/packaging/${APP_ID}.desktop"
METAINFO_SRC="linux/packaging/${APP_ID}.metainfo.xml"
ICON_DIR="linux/packaging/icons/hicolor"
ICON_SIZES="16 24 32 48 64 128 256 512"
BUNDLE_DIR="build/linux/x64/release/bundle"
OUT_DIR="$ROOT/dist"

# The runtime libraries the bundle links directly (ldd-verified: everything else
# is pulled in transitively by GTK3). Two spellings each for GTK and GLib: the
# 64-bit time_t transition renamed them in Ubuntu 24.04 / Debian 13, and a
# package that names only one of the two is uninstallable on half the target
# releases. The libc6/libstdc++6 minimums are the BUILD BASELINE — the release
# workflow builds on ubuntu-latest (24.04 noble: glibc 2.39, libstdc++ 13.2), so
# the binary really does need at least those. Loosening them would let apt
# install a package onto a host too old to run it.
DEPENDS="libgtk-3-0t64 (>= 3.24.41) | libgtk-3-0 (>= 3.24.41), libglib2.0-0t64 (>= 2.80.0) | libglib2.0-0 (>= 2.80.0), libstdc++6 (>= 13.2), libc6 (>= 2.39)"

# The packaging changelog carries a FIXED date on purpose: what changed in a
# release is the GitHub release notes, generated from the commits, and a
# wall-clock date here would make two builds of the same tree differ.
CHANGELOG_DATE="Mon, 07 Sep 2026 00:00:00 +0000"

# Whether the packaged app carries the OAuth client credentials (#229).
# shellcheck source=tool/oauth_defines.sh
. "$ROOT/tool/oauth_defines.sh"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Version: `version: X.Y.Z+B` in pubspec → the Debian version X.Y.Z-B.
#    dpkg compares this string when deciding what is an upgrade, so it has to
#    track pubspec exactly.
read_version() {
  local raw
  raw=$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]*#.*$//')
  [ -n "$raw" ] || die "could not read version from pubspec.yaml"
  VERSION="${raw%%+*}"
  local build="${raw##*+}"
  [ "$build" = "$raw" ] && build=1   # no +B present
  RELEASE="$build"
  DEB_VERSION="${VERSION}-${RELEASE}"
}

# ── DEBIAN/control. The single source of the package metadata; the packaging
#    test reads it back through --print-control.
render_control() {
  read_version
  cat <<CONTROL
Package: ${PKG_NAME}
Version: ${DEB_VERSION}
Architecture: amd64
Maintainer: ${MAINTAINER}
Section: utils
Priority: optional
Depends: ${DEPENDS}
Homepage: ${URL}
Description: ${SUMMARY}
 axiotask is a fast, local-first frontend for Google Tasks. One Flutter
 codebase, one UI, for Linux desktop and Android: it keeps your lists in a
 local database, launches in under two seconds and stays fully usable
 offline, syncing back to Google as soon as you are connected again.
 .
 Smart views across every list, one-gesture complete/schedule/reorder,
 subtasks, notes and due dates in a task detail panel.
CONTROL
}

render_copyright() {
  cat <<'COPYRIGHT'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: axiotask
Source: https://github.com/IllyaYalovyy/axiotask

Files: *
Copyright: 2026 Illya Yalovyy
License: GPL-3.0-or-later

Files: usr/lib/axiotask/lib/* usr/lib/axiotask/data/*
Copyright: The Flutter Authors and the authors of the bundled packages
License: BSD-3-clause and others
 The application bundle embeds the Flutter engine and the third-party Dart
 packages the application depends on. Their full license texts are shipped
 with the bundle itself, in
 /usr/lib/axiotask/data/flutter_assets/NOTICES.Z (zlib-compressed), which is
 the notice file the application displays.

License: GPL-3.0-or-later
 This program is free software: you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the Free
 Software Foundation, either version 3 of the License, or (at your option)
 any later version.
 .
 This program is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 more details.
 .
 On Debian systems, the complete text of the GNU General Public License
 version 3 can be found in "/usr/share/common-licenses/GPL-3".
COPYRIGHT
}

render_changelog() {
  cat <<CHANGELOG
${PKG_NAME} (${DEB_VERSION}) unstable; urgency=medium

  * Release ${VERSION}. The per-release changes are the GitHub release notes,
    generated from the commits since the previous tag:
    ${URL}/releases/tag/v${VERSION}
  * Built by tool/build_deb.sh from the same bundle as the RPM.

 -- ${MAINTAINER}  ${CHANGELOG_DATE}
CHANGELOG
}

# Lintian overrides — the release workflow runs `lintian --fail-on error,warning`
# on the package, so a tag lintian cannot be told about would block every
# release. Each entry below is a deliberate property of shipping a self-contained
# Flutter bundle, and each one MUST carry the comment that says why; the
# packaging test fails on an override without one.
render_lintian_overrides() {
  cat <<OVERRIDES
# The runner finds the engine and the plugin libraries through the RUNPATH
# \$ORIGIN/lib that the Flutter toolchain links in: they are private to this
# application, live next to the binary in /usr/lib/axiotask/lib and are
# deliberately on no system search path. The plugin libraries additionally keep
# the RUNPATH of the directory they were BUILT in, which the loader never uses
# (the engine is already resolved through the runner).
${PKG_NAME}: custom-library-search-path
# The plugin libraries link against the Flutter engine without repeating its
# transitive dependencies. Nothing outside this bundle loads them, and the
# runner has already pulled in everything they need.
${PKG_NAME}: shared-library-lacks-prerequisites
# The application bundle embeds its own SQLite (sqlite3_flutter_libs) and the
# Dart/Flutter runtime. Both are compiled into the bundle by the Flutter build,
# with versions the store is tested against; using the system copies is not
# something a packaging script can decide.
${PKG_NAME}: embedded-library
# The program is a GUI application with no command-line interface to document;
# it is launched from the desktop entry that ships with it.
${PKG_NAME}: no-manual-page
# The Flutter release binary and the engine are shipped exactly as the
# toolchain produced them. Stripping them separates a crash from its stack
# trace, and re-linking a prebuilt engine is not something a packaging script
# may do.
${PKG_NAME}: unstripped-binary-or-object
OVERRIDES
}

# ── Stage the package root: DEBIAN/ plus the installed tree.
stage_package() {
  local root="$1"
  read_version
  [ -d "$BUNDLE_DIR" ] || die "release bundle not found at $BUNDLE_DIR (run: flutter build linux --release)"
  [ -x "$BUNDLE_DIR/${PKG_NAME}" ] || die "release binary missing at $BUNDLE_DIR/${PKG_NAME}"

  install -d -m 0755 "$root/DEBIAN" "$root/usr/lib/${PKG_NAME}" "$root/usr/bin" \
                     "$root/usr/share/applications" \
                     "$root/usr/share/doc/${PKG_NAME}" \
                     "$root/usr/share/lintian/overrides"

  cp -a "$BUNDLE_DIR/." "$root/usr/lib/${PKG_NAME}/"
  # Normalise the bundle's permissions: whatever umask the build ran under, the
  # package must ship 0755 directories/executables and 0644 data, or lintian
  # reports non-standard permissions and a group-writable install lands on the
  # user's machine.
  chmod -R u=rwX,go=rX "$root/usr/lib/${PKG_NAME}"
  # Relative, per Debian policy 10.5 — /usr/bin and /usr/lib share a top-level
  # directory, and an absolute link breaks when the tree is unpacked elsewhere.
  ln -sf "../lib/${PKG_NAME}/${PKG_NAME}" "$root/usr/bin/${PKG_NAME}"

  install -Dm644 "$DESKTOP_SRC" "$root/usr/share/applications/${APP_ID}.desktop"
  for s in ${ICON_SIZES}; do
    src="${ICON_DIR}/${s}x${s}/apps/${PKG_NAME}.png"
    [ -f "$src" ] || die "icon $src missing — run tool/gen_icons.py"
    install -Dm644 "$src" "$root/usr/share/icons/hicolor/${s}x${s}/apps/${PKG_NAME}.png"
  done
  install -Dm644 "${ICON_DIR}/scalable/apps/${PKG_NAME}.svg" \
    "$root/usr/share/icons/hicolor/scalable/apps/${PKG_NAME}.svg"
  install -Dm644 "$METAINFO_SRC" "$root/usr/share/metainfo/${APP_ID}.metainfo.xml"

  render_copyright > "$root/usr/share/doc/${PKG_NAME}/copyright"
  chmod 0644 "$root/usr/share/doc/${PKG_NAME}/copyright"
  # -9n: maximum compression, no timestamp — the same tree must produce the
  # same bytes, and lintian requires maximum compression.
  render_changelog | gzip -9n > "$root/usr/share/doc/${PKG_NAME}/changelog.Debian.gz"
  chmod 0644 "$root/usr/share/doc/${PKG_NAME}/changelog.Debian.gz"
  render_lintian_overrides > "$root/usr/share/lintian/overrides/${PKG_NAME}"
  chmod 0644 "$root/usr/share/lintian/overrides/${PKG_NAME}"

  render_control > "$root/DEBIAN/control"
  chmod 0644 "$root/DEBIAN/control"

  # The icon and desktop caches: without a refresh the freshly installed app has
  # no icon and no menu entry until the next login. `|| :` because a cache tool
  # missing on a minimal system must not fail the install.
  cat > "$root/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || :
  fi
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || :
  fi
fi
exit 0
POSTINST
  cat > "$root/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || :
  fi
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || :
  fi
fi
exit 0
POSTRM
  chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

  # md5sums: what `dpkg -V` and debsums verify an install against. Regular files
  # only — symlinks and the control files are deliberately not listed.
  ( cd "$root" && find usr -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 md5sum ) > "$root/DEBIAN/md5sums"
  chmod 0644 "$root/DEBIAN/md5sums"
}

# ── Static validation: fail loud on a broken config, before anything is built.
validate_config() {
  [ -f pubspec.yaml ] || die "pubspec.yaml missing"
  [ -f "$DESKTOP_SRC" ] || die "desktop entry missing at $DESKTOP_SRC"
  grep -q '^Exec=axiotask$' "$DESKTOP_SRC" || die "desktop Exec= must be 'axiotask' (matches /usr/bin/axiotask)"
  # #227 identity guard, the same one the RPM makes: the running window's
  # Wayland app_id IS APPLICATION_ID, and GNOME finds the window's icon only
  # through a desktop file of that exact basename.
  cmake_app_id=$(sed -nE 's/^set\(APPLICATION_ID "([^"]+)"\).*/\1/p' linux/CMakeLists.txt)
  [ "$cmake_app_id" = "$APP_ID" ] || die \
    "app-id drift: linux/CMakeLists.txt says '$cmake_app_id' but packaging uses '$APP_ID' — the installed window would have no icon"
  grep -q "^StartupWMClass=${APP_ID}\$" "$DESKTOP_SRC" \
    || die "desktop StartupWMClass= must be '$APP_ID' (the X11 half of the same match)"
  for s in ${ICON_SIZES}; do
    [ -f "${ICON_DIR}/${s}x${s}/apps/${PKG_NAME}.png" ] \
      || die "hicolor icon ${s}x${s} missing — run tool/gen_icons.py"
  done
  [ -f "${ICON_DIR}/scalable/apps/${PKG_NAME}.svg" ] || die "scalable icon missing — run tool/gen_icons.py"
  [ -f "$METAINFO_SRC" ] || die "AppStream metainfo missing at $METAINFO_SRC"
  if command -v appstreamcli >/dev/null; then
    appstreamcli validate --no-net "$METAINFO_SRC" >/dev/null \
      || die "appstreamcli validate failed for $METAINFO_SRC (run it for details)"
  else
    warn "appstreamcli not installed — metainfo left unvalidated (dnf install appstream)"
  fi
  if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$DESKTOP_SRC" \
      || die "desktop-file-validate failed for $DESKTOP_SRC"
  else
    warn "desktop-file-validate not installed — desktop entry left unvalidated"
  fi
  read_version
}

MODE="build"
STAGE_ROOT=""
BUNDLE_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --print-control) MODE="print-control"; shift ;;
    --dry-run)       MODE="dry-run"; shift ;;
    --stage)         MODE="stage"; STAGE_ROOT="${2:-}"
                     [ -n "$STAGE_ROOT" ] || die "--stage needs a directory"; shift 2 ;;
    --bundle)        BUNDLE_DIR="${2:-}"; BUNDLE_GIVEN=1
                     [ -n "$BUNDLE_DIR" ] || die "--bundle needs a directory"; shift 2 ;;
    --out)           OUT_DIR="${2:-}"
                     [ -n "$OUT_DIR" ] || die "--out needs a directory"; shift 2 ;;
    *) die "unknown argument: $1 (use: --dry-run | --print-control | --stage DIR | --bundle DIR | --out DIR)" ;;
  esac
done

case "$MODE" in
  print-control)
    render_control
    exit 0
    ;;
  stage)
    validate_config
    mkdir -p "$STAGE_ROOT" || die "could not create $STAGE_ROOT"
    stage_package "$STAGE_ROOT"
    info "staged package root -> $STAGE_ROOT"
    exit 0
    ;;
  dry-run)
    validate_config
    info "config OK — package ${PKG_NAME} ${DEB_VERSION} (amd64)"
    if [ -d "$BUNDLE_DIR" ]; then
      info "release bundle present: $BUNDLE_DIR ($(du -sh "$BUNDLE_DIR" | cut -f1))"
    else
      warn "release bundle NOT built yet — real build will run: flutter build linux --release"
    fi
    if command -v dpkg-deb >/dev/null; then
      info "dpkg-deb available: $(command -v dpkg-deb)"
    else
      warn "dpkg-deb NOT installed — real build needs: sudo dnf install dpkg"
    fi
    if command -v lintian >/dev/null; then
      info "lintian available: $(command -v lintian)"
    else
      warn "lintian NOT installed — the release workflow checks the package with it"
    fi
    info "DRY RUN OK. Real build would run:"
    printf '      dpkg-deb --root-owner-group --build <staged> %s/%s_%s_amd64.deb\n' \
      "$OUT_DIR" "$PKG_NAME" "$DEB_VERSION" >&2
    exit 0
    ;;
esac

# ── Real build ──────────────────────────────────────────────────────────────
validate_config
command -v dpkg-deb >/dev/null || die "dpkg-deb not found — sudo dnf install dpkg"

if [ "$BUNDLE_GIVEN" = "1" ]; then
  info "Using the bundle passed with --bundle: $BUNDLE_DIR (skipping flutter build)"
else
  command -v flutter >/dev/null || die "flutter not on PATH (or pass --bundle DIR)"
  oauth_define_args
  info "$(oauth_defines_report)"
  info "Building release bundle (flutter build linux --release)..."
  flutter build linux --release ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"} \
    || die "flutter build linux --release failed"
fi

PKGROOT="$(mktemp -d)"
cleanup() { rm -rf "$PKGROOT"; }
trap cleanup EXIT

stage_package "$PKGROOT"
mkdir -p "$OUT_DIR" || die "could not create $OUT_DIR"
DEB_FILE="$OUT_DIR/${PKG_NAME}_${DEB_VERSION}_amd64.deb"

info "Running dpkg-deb..."
# --root-owner-group: the files must be owned by root in the package, not by
# whoever ran the build — a uid 1000 install is unusable.
dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB_FILE" >&2 \
  || die "dpkg-deb failed"

info "DEB built -> $DEB_FILE"
info "Install with: sudo apt install $DEB_FILE"
