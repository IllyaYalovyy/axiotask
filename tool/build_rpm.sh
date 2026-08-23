#!/usr/bin/env bash
# Build an installable RPM of the axiotask Linux desktop app WITHOUT fastforge.
#
# This is the standalone path (the fastforge path is `flutter_distributor
# package --platform linux --targets rpm` — see distribute_options.yaml). It
# renders an RPM spec whose metadata mirrors linux/packaging/rpm/make_config.yaml,
# stages the `flutter build linux --release` bundle, and calls rpmbuild.
#
# Layout the RPM installs:
#   /usr/lib/axiotask/                 the whole release bundle (binary, data, lib)
#   /usr/bin/axiotask                  symlink -> /usr/lib/axiotask/axiotask
#   /usr/share/applications/io.github.illyayalovyy.axiotask.desktop
#   /usr/share/icons/hicolor/<size>/apps/axiotask.png   (16..512 + scalable SVG)
#   /usr/share/metainfo/io.github.illyayalovyy.axiotask.metainfo.xml (AppStream)
#
# Usage:
#   tool/build_rpm.sh                build the RPM (needs flutter + rpmbuild)
#   tool/build_rpm.sh --dry-run      validate config + render spec + report the
#                                    exact rpmbuild command, WITHOUT building
#                                    (never invokes rpmbuild; always exits 0 on
#                                    a valid config — this is the gate check)
#   tool/build_rpm.sh --print-spec   render the spec to stdout and exit
#   tool/build_rpm.sh --stage DIR    stage the buildroot %files describes into
#                                    DIR and exit (no rpmbuild). Combined with
#                                    --bundle it needs neither flutter nor rpm,
#                                    which is how the packaging test proves the
#                                    spec and the staged tree agree.
#   tool/build_rpm.sh --bundle DIR   use an already-built release bundle
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG_NAME="axiotask"
SUMMARY="Fast, offline-first Google Tasks client"
LICENSE="GPLv3+"
URL="https://github.com/IllyaYalovyy/axiotask"
# The ONE application id (#227): the AppStream component id, the metainfo file
# name, the desktop-entry basename and the GTK APPLICATION_ID the runner sets
# are all this string. The desktop entry MUST be installed under it — GNOME on
# Wayland resolves a running window's icon by matching the window's app_id to a
# desktop file of the same basename, so any other name means a blank dash icon.
# ${PKG_NAME} stays the RPM package, the binary and the icon theme name.
APP_ID="io.github.illyayalovyy.axiotask"
DESKTOP_SRC="linux/packaging/${APP_ID}.desktop"
METAINFO_SRC="linux/packaging/${APP_ID}.metainfo.xml"
# Icons: the hicolor theme tree rendered from the SVG master by tool/gen_icons.py.
# The desktop entry says `Icon=axiotask`, which only resolves if every themed
# size is installed under /usr/share/icons/hicolor (a lone 512px bitmap makes
# GNOME scale one icon down for the 16px list, badly).
ICON_DIR="linux/packaging/icons/hicolor"
ICON_SIZES="16 24 32 48 64 128 256 512"
BUNDLE_DIR="build/linux/x64/release/bundle"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Version: parse `version: X.Y.Z+B` from pubspec (X.Y.Z → Version, B → Release)
read_version() {
  local raw
  raw=$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]*#.*$//')
  [ -n "$raw" ] || die "could not read version from pubspec.yaml"
  VERSION="${raw%%+*}"
  local build="${raw##*+}"
  [ "$build" = "$raw" ] && build=1   # no +B present
  RELEASE="$build"
}

# ── Render the RPM spec to stdout. Single source of the RPM metadata; kept in
#    sync with linux/packaging/rpm/make_config.yaml (enforced by the test).
render_spec() {
  read_version
  cat <<SPEC
Name:           ${PKG_NAME}
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        ${SUMMARY}
License:        ${LICENSE}
URL:            ${URL}

# The bundle is a prebuilt x86_64 tree of shared objects; do not let rpmbuild
# strip/repack it or generate auto-requires from the vendored *.so files.
AutoReqProv:    no
Requires:       gtk3
Requires:       glib2
%global __brp_strip %{nil}
%global __brp_strip_static_archive %{nil}
%global debug_package %{nil}

%description
axiotask is a fast, local-first frontend for Google Tasks. One Flutter
codebase, one UI, for Linux desktop and Android: launches in under two
seconds, fully usable offline, and every frequent action is one gesture.

%files
/usr/lib/${PKG_NAME}
/usr/bin/${PKG_NAME}
/usr/share/applications/${APP_ID}.desktop
$(for s in ${ICON_SIZES}; do echo "/usr/share/icons/hicolor/${s}x${s}/apps/${PKG_NAME}.png"; done)
/usr/share/icons/hicolor/scalable/apps/${PKG_NAME}.svg
/usr/share/metainfo/${APP_ID}.metainfo.xml

%post
/usr/bin/gtk-update-icon-cache -f /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database /usr/share/applications &>/dev/null || :

%postun
/usr/bin/gtk-update-icon-cache -f /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database /usr/share/applications &>/dev/null || :

%changelog
* Mon Jan 01 2024 axiotask packaging <noreply@axiotask.dev> - ${VERSION}-${RELEASE}
- Automated build via tool/build_rpm.sh
SPEC
}

# ── Stage the buildroot that %files describes, from an existing release bundle.
stage_buildroot() {
  local root="$1"
  [ -d "$BUNDLE_DIR" ] || die "release bundle not found at $BUNDLE_DIR (run: flutter build linux --release)"
  [ -x "$BUNDLE_DIR/${PKG_NAME}" ] || die "release binary missing at $BUNDLE_DIR/${PKG_NAME}"

  install -d "$root/usr/lib/${PKG_NAME}" "$root/usr/bin" \
             "$root/usr/share/applications"
  cp -a "$BUNDLE_DIR/." "$root/usr/lib/${PKG_NAME}/"
  ln -sf "/usr/lib/${PKG_NAME}/${PKG_NAME}" "$root/usr/bin/${PKG_NAME}"
  install -Dm644 "$DESKTOP_SRC" "$root/usr/share/applications/${APP_ID}.desktop"
  for s in ${ICON_SIZES}; do
    src="${ICON_DIR}/${s}x${s}/apps/${PKG_NAME}.png"
    [ -f "$src" ] || die "icon $src missing — run tool/gen_icons.py"
    install -Dm644 "$src" \
      "$root/usr/share/icons/hicolor/${s}x${s}/apps/${PKG_NAME}.png"
  done
  install -Dm644 "${ICON_DIR}/scalable/apps/${PKG_NAME}.svg" \
    "$root/usr/share/icons/hicolor/scalable/apps/${PKG_NAME}.svg"
  install -Dm644 "$METAINFO_SRC" \
    "$root/usr/share/metainfo/${APP_ID}.metainfo.xml"
}

# ── Static validation shared by --dry-run: fail loud on a broken config.
validate_config() {
  [ -f pubspec.yaml ] || die "pubspec.yaml missing"
  [ -f "$DESKTOP_SRC" ] || die "desktop entry missing at $DESKTOP_SRC"
  [ -f linux/packaging/rpm/make_config.yaml ] || die "fastforge make_config.yaml missing"
  grep -q '^Exec=axiotask$' "$DESKTOP_SRC" || die "desktop Exec= must be 'axiotask' (matches /usr/bin/axiotask)"
  # #227 identity guard: the running window's Wayland app_id IS APPLICATION_ID,
  # and GNOME only finds the window's icon through a desktop file of that exact
  # basename. Packaging a desktop entry named anything else ships a blank icon.
  cmake_app_id=$(sed -nE 's/^set\(APPLICATION_ID "([^"]+)"\).*/\1/p' linux/CMakeLists.txt)
  [ "$cmake_app_id" = "$APP_ID" ] || die \
    "app-id drift: linux/CMakeLists.txt says '$cmake_app_id' but packaging uses '$APP_ID' — the installed window would have no icon"
  grep -q "^StartupWMClass=${APP_ID}\$" "$DESKTOP_SRC" \
    || die "desktop StartupWMClass= must be '$APP_ID' (the X11 half of the same match)"
  # Icon=axiotask only resolves if the themed bitmaps are actually there.
  for s in ${ICON_SIZES}; do
    [ -f "${ICON_DIR}/${s}x${s}/apps/${PKG_NAME}.png" ] \
      || die "hicolor icon ${s}x${s} missing — run tool/gen_icons.py"
  done
  [ -f "${ICON_DIR}/scalable/apps/${PKG_NAME}.svg" ] || die "scalable icon missing — run tool/gen_icons.py"
  [ -f "$METAINFO_SRC" ] || die "AppStream metainfo missing at $METAINFO_SRC"
  # Validate the two metadata files when the freedesktop validators are here.
  # A package that ships invalid AppStream data is listed nowhere; catching it
  # at config-validation time is cheaper than after the rpmbuild.
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
    --print-spec) MODE="print-spec"; shift ;;
    --dry-run)    MODE="dry-run"; shift ;;
    --stage)      MODE="stage"; STAGE_ROOT="${2:-}"
                  [ -n "$STAGE_ROOT" ] || die "--stage needs a directory"; shift 2 ;;
    --bundle)     BUNDLE_DIR="${2:-}"; BUNDLE_GIVEN=1
                  [ -n "$BUNDLE_DIR" ] || die "--bundle needs a directory"; shift 2 ;;
    *) die "unknown argument: $1 (use: --dry-run | --print-spec | --stage DIR | --bundle DIR)" ;;
  esac
done

case "$MODE" in
  print-spec)
    render_spec
    exit 0
    ;;
  stage)
    validate_config
    mkdir -p "$STAGE_ROOT" || die "could not create $STAGE_ROOT"
    stage_buildroot "$STAGE_ROOT"
    info "staged buildroot -> $STAGE_ROOT"
    exit 0
    ;;
  dry-run)
    validate_config
    info "config OK — package ${PKG_NAME} ${VERSION}-${RELEASE}"
    spec_tmp="$(mktemp)"
    render_spec > "$spec_tmp"
    info "rendered spec -> $spec_tmp ($(wc -l < "$spec_tmp") lines)"
    if [ -d "$BUNDLE_DIR" ]; then
      info "release bundle present: $BUNDLE_DIR ($(du -sh "$BUNDLE_DIR" | cut -f1))"
    else
      warn "release bundle NOT built yet — real build will run: flutter build linux --release"
    fi
    if command -v rpmbuild >/dev/null; then
      info "rpmbuild available: $(command -v rpmbuild)"
    else
      warn "rpmbuild NOT installed — real build needs: sudo dnf install rpm-build"
    fi
    info "DRY RUN OK. Real build would run:"
    printf '      rpmbuild -bb --define "_topdir <tmp>" --buildroot <staged> %s.spec\n' "$PKG_NAME" >&2
    rm -f "$spec_tmp"
    exit 0
    ;;
esac

# ── Real build ──────────────────────────────────────────────────────────────
validate_config
command -v rpmbuild >/dev/null || die "rpmbuild not found — sudo dnf install rpm-build"

if [ "$BUNDLE_GIVEN" = "1" ]; then
  info "Using the bundle passed with --bundle: $BUNDLE_DIR (skipping flutter build)"
else
  command -v flutter >/dev/null || die "flutter not on PATH (or pass --bundle DIR)"
  info "Building release bundle (flutter build linux --release)..."
  flutter build linux --release || die "flutter build linux --release failed"
fi

TOPDIR="$(mktemp -d)"
BUILDROOT="$(mktemp -d)"
cleanup() { rm -rf "$TOPDIR" "$BUILDROOT"; }
trap cleanup EXIT

mkdir -p "$TOPDIR/SPECS" "$TOPDIR/RPMS"
render_spec > "$TOPDIR/SPECS/${PKG_NAME}.spec"
stage_buildroot "$BUILDROOT"

info "Running rpmbuild..."
rpmbuild -bb \
  --define "_topdir $TOPDIR" \
  --buildroot "$BUILDROOT" \
  "$TOPDIR/SPECS/${PKG_NAME}.spec" || die "rpmbuild failed"

OUT_DIR="$ROOT/dist"
mkdir -p "$OUT_DIR"
rpm_file=$(find "$TOPDIR/RPMS" -name '*.rpm' | head -1)
[ -n "$rpm_file" ] || die "rpmbuild produced no .rpm"
cp -f "$rpm_file" "$OUT_DIR/"
info "RPM built -> $OUT_DIR/$(basename "$rpm_file")"
info "Install with: sudo dnf install $OUT_DIR/$(basename "$rpm_file")"
