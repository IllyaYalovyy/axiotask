#!/usr/bin/env bash
# Build and run an ISOLATED development instance of axiotask on Linux.
#
# Never launches against production data: the instance prefix (default: flt)
# roots all state in
#   ${XDG_DATA_HOME:-~/.local/share}/axiotask-<prefix>/   DB, tokens, prefs, backups
#   ${XDG_CONFIG_HOME:-~/.config}/axiotask-<prefix>/      config.json
# while the production app uses the unprefixed axiotask/ directories.
#
# The default is flt, NOT dev: the Tauri/Rust app's documented dev instance
# already owns the axiotask-dev/ directories, and its database schema is not
# this app's. Sharing a prefix across the two implementations corrupts the
# instance; pick per-implementation prefixes.
#
# Usage: tool/dev.sh [options]
#   --release        build the release bundle and run it standalone
#   --bundle         build the debug bundle and run it standalone (no tooling)
#   --prefix NAME    instance prefix (default: dev)
#   --fresh          wipe the instance's data and config before launching
#
# Google sign-in works with no config.json editing when tool/oauth_credentials.json
# exists (see tool/oauth_defines.sh); the instance's own config.json overrides it.
#
# Default mode runs under `flutter run -d linux`, which is the only mode that
# shows the app's log output (the logger writes through dart:developer, which
# standalone binaries do not print). Use the default mode when debugging;
# use --bundle/--release to test the real deployed artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

# The OAuth client credentials this build carries (#229). A dev instance gets
# the same treatment as an install: if the operator created the gitignored
# credentials file, sign-in works with no config.json editing at all.
# shellcheck source=tool/oauth_defines.sh
. "$PWD/tool/oauth_defines.sh"

prefix=flt
mode=run
fresh=0
while [ $# -gt 0 ]; do
  case "$1" in
    --release) mode=release ;;
    --bundle)  mode=bundle ;;
    --prefix)  shift; prefix="${1:?--prefix needs a name}" ;;
    --fresh)   fresh=1 ;;
    *) echo "unknown option: $1 (see header of $0)" >&2; exit 2 ;;
  esac
  shift
done

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/axiotask-$prefix"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/axiotask-$prefix"

if [ "$fresh" = 1 ]; then
  echo "wiping instance '$prefix': $data_dir $config_dir"
  rm -rf "$data_dir" "$config_dir"
fi

oauth_define_args

echo "instance '$prefix' (data: $data_dir)"
oauth_defines_report
echo "$config_dir/config.json overrides the bundled credentials — see README."

case "$mode" in
  run)
    exec env AXIOTASK_PREFIX="$prefix" \
      flutter run -d linux --debug ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"}
    ;;
  bundle)
    flutter build linux --debug ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"}
    exec env AXIOTASK_PREFIX="$prefix" build/linux/x64/debug/bundle/axiotask
    ;;
  release)
    flutter build linux --release ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"}
    exec env AXIOTASK_PREFIX="$prefix" build/linux/x64/release/bundle/axiotask
    ;;
esac
