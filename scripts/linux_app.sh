#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' \
    "Usage: ${0##*/} run" \
    "       ${0##*/} dev" \
    "       ${0##*/} build <debug|release>" \
    "       ${0##*/} build-dev <debug|release>" \
    "       ${0##*/} install <debug|release> <absolute-directory>" \
    "       ${0##*/} remove <absolute-directory>" \
    "       ${0##*/} synthetic <isolated-instance>" >&2
}

fail() {
  printf 'Linux app command failed: %s\n' "$1" >&2
  exit 1
}

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cleanup_directory=

cleanup() {
  if [[ -n "$cleanup_directory" && -d "$cleanup_directory" ]]; then
    rm -rf -- "$cleanup_directory"
  fi
}
trap cleanup EXIT

require_flutter() {
  command -v flutter >/dev/null 2>&1 || fail "required command 'flutter' is unavailable"
}

run_production() {
  require_flutter
  cd "$repository_root"
  flutter run -d linux --debug -t lib/main.dart
}

run_development() {
  require_flutter
  cd "$repository_root"
  flutter run -d linux --debug -t lib/main_development.dart
}

build_production() {
  local mode=$1
  require_flutter
  cd "$repository_root"
  flutter build linux "--$mode" -t lib/main.dart
}

build_development() {
  local mode=$1
  require_flutter
  cd "$repository_root"
  flutter build linux "--$mode" -t lib/main_development.dart
}

validate_local_target() {
  local supplied_target=$1
  [[ "$supplied_target" == /* ]] ||
    fail 'local install target must be an absolute directory'

  local target
  target=$(realpath -m -- "$supplied_target") ||
    fail 'local install target cannot be resolved'
  case "$target" in
    / | /bin | /bin/* | /boot | /boot/* | /dev | /dev/* | /etc | /etc/* | \
      /lib | /lib/* | /lib32 | /lib32/* | /lib64 | /lib64/* | /opt | /opt/* | \
      /proc | /proc/* | /root | /root/* | /run | /run/* | /sbin | /sbin/* | \
      /sys | /sys/* | /usr | /usr/* | /var | /var/*)
      fail 'refusing a system install target'
      ;;
  esac
  [[ "$target" != "$repository_root" && "$target" != "$repository_root/"* ]] ||
    fail 'refusing to install a bundle inside the source worktree'

  local user_home
  user_home=$(getent passwd "$(id -u)" | cut -d: -f6)
  [[ -n "$user_home" && "$user_home" == /* ]] ||
    fail 'current user home directory cannot be determined safely'
  [[ "$target" != "$user_home" ]] ||
    fail 'refusing to use the user home directory itself as an install target'
  [[ "$target" == "$user_home/"* ]] ||
    fail 'local install target must be inside the current user home directory'
  printf '%s\n' "$target"
}

bundle_directory() {
  local mode=$1 architecture
  case "$(uname -m)" in
    x86_64 | amd64) architecture=x64 ;;
    aarch64 | arm64) architecture=arm64 ;;
    *) fail 'this Linux architecture has no known Flutter bundle path' ;;
  esac
  printf '%s/build/linux/%s/%s/bundle\n' \
    "$repository_root" "$architecture" "$mode"
}

install_local_bundle() {
  local mode=$1 supplied_target=$2 target parent source_bundle
  target=$(validate_local_target "$supplied_target")
  [[ ! -e "$target" ]] ||
    fail 'local install target already exists; remove it explicitly first'

  build_production "$mode"
  source_bundle=$(bundle_directory "$mode")
  [[ -d "$source_bundle" && -x "$source_bundle/axiotask" ]] ||
    fail 'Flutter did not produce the expected Linux bundle'

  parent=${target%/*}
  mkdir -p -- "$parent"
  [[ -d "$parent" && -w "$parent" ]] ||
    fail 'local install parent directory is not writable'
  cleanup_directory=$(mktemp -d "$parent/.axiotask-install-XXXXXX") ||
    fail 'could not create a temporary local install directory'
  cp -a -- "$source_bundle/." "$cleanup_directory/"
  printf '%s\n' 'Axiotask user-local bundle' "mode=$mode" \
    >"$cleanup_directory/.axiotask-local-install"
  [[ ! -e "$target" ]] ||
    fail 'local install target appeared while the bundle was being prepared'
  mv -T -- "$cleanup_directory" "$target"
  cleanup_directory=
  printf 'Installed the Axiotask %s bundle at %s\n' "$mode" "$target"
}

remove_local_bundle() {
  local target
  target=$(validate_local_target "$1")
  [[ -d "$target" && ! -L "$target" && \
    -f "$target/.axiotask-local-install" ]] ||
    fail 'target is not an Axiotask local install'
  [[ "$(sed -n '1p' "$target/.axiotask-local-install")" == \
    'Axiotask user-local bundle' ]] ||
    fail 'target is not an Axiotask local install'
  rm -rf -- "$target"
  printf 'Removed the Axiotask local bundle at %s\n' "$target"
}

run_synthetic() {
  local instance=$1
  [[ "$instance" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] ||
    fail 'invalid synthetic instance; use lowercase letters, digits, and hyphens'
  require_flutter
  cd "$repository_root"
  flutter run -d linux --debug -t lib/main_test.dart \
    "--dart-define=AXIOTASK_TEST_INSTANCE=$instance"
}

[[ $# -ge 1 ]] || {
  usage
  exit 2
}

command_name=$1
shift
case "$command_name" in
  run)
    [[ $# -eq 0 ]] || {
      usage
      exit 2
    }
    run_production
    ;;
  dev)
    [[ $# -eq 0 ]] || {
      usage
      exit 2
    }
    run_development
    ;;
  build)
    [[ $# -eq 1 && ("$1" == debug || "$1" == release) ]] || {
      usage
      exit 2
    }
    mode=$1
    build_production "$mode"
    ;;
  build-dev)
    [[ $# -eq 1 && ("$1" == debug || "$1" == release) ]] || {
      usage
      exit 2
    }
    build_development "$1"
    ;;
  install)
    [[ $# -eq 2 && ("$1" == debug || "$1" == release) ]] || {
      usage
      exit 2
    }
    mode=$1
    target=$2
    install_local_bundle "$mode" "$target"
    ;;
  remove)
    [[ $# -eq 1 ]] || {
      usage
      exit 2
    }
    remove_local_bundle "$1"
    ;;
  synthetic)
    [[ $# -eq 1 ]] || {
      usage
      exit 2
    }
    run_synthetic "$1"
    ;;
  *)
    usage
    exit 2
    ;;
esac
