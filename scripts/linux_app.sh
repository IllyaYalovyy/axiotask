#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' \
    "Usage: ${0##*/} run [--config <private.env>]" \
    "       ${0##*/} build <debug|release> [--config <private.env>]" \
    "       ${0##*/} install <debug|release> <absolute-directory> [--config <private.env>]" \
    "       ${0##*/} remove <absolute-directory>" \
    "       ${0##*/} synthetic <isolated-instance>" >&2
}

fail() {
  printf 'Linux app command failed: %s\n' "$1" >&2
  exit 1
}

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
default_config="$repository_root/.ktask/gates/stage7.env"
config_path=$default_config
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

parse_config_option() {
  if [[ $# -eq 0 ]]; then
    return
  fi
  if [[ $# -ne 2 || "$1" != '--config' || -z "$2" ]]; then
    usage
    exit 2
  fi
  config_path=$2
}

validate_private_config() {
  [[ -e "$config_path" ]] ||
    fail 'private configuration is missing; create .ktask/gates/stage7.env'
  [[ -f "$config_path" && ! -L "$config_path" && -r "$config_path" ]] ||
    fail 'private configuration must be a readable regular file, not a symlink'

  local mode owner
  mode=$(stat -c '%a' -- "$config_path") ||
    fail 'private configuration metadata is unavailable'
  [[ "$mode" == '600' ]] ||
    fail 'private configuration permissions must be 600'
  owner=$(stat -c '%u' -- "$config_path") ||
    fail 'private configuration ownership is unavailable'
  [[ "$owner" == "$(id -u)" ]] ||
    fail 'private configuration must be owned by the current user'

  local canonical_config
  canonical_config=$(realpath -- "$config_path") ||
    fail 'private configuration path cannot be resolved'
  if [[ "$canonical_config" == "$repository_root/"* ]]; then
    git -C "$repository_root" check-ignore -q -- "$canonical_config" ||
      fail 'private configuration inside the repository must be ignored by Git'
  fi
  config_path=$canonical_config

  declare -A seen=()
  local line key value client_id='' client_secret=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] ||
      fail 'private configuration contains an invalid line'
    key=${line%%=*}
    value=${line#*=}
    [[ ! -v "seen[$key]" ]] ||
      fail 'private configuration repeats a key'
    seen["$key"]=1
    case "$key" in
      AXIOTASK_LINUX_AUTH_CLIENT_ID) client_id=$value ;;
      AXIOTASK_LINUX_AUTH_CLIENT_SECRET) client_secret=$value ;;
    esac
  done <"$config_path"

  [[ -n "$client_id" ]] ||
    fail "private configuration is missing 'AXIOTASK_LINUX_AUTH_CLIENT_ID'"
  [[ "$client_id" == *.apps.googleusercontent.com ]] ||
    fail "private configuration has an invalid 'AXIOTASK_LINUX_AUTH_CLIENT_ID'"
  [[ -n "$client_secret" ]] ||
    fail "private configuration is missing 'AXIOTASK_LINUX_AUTH_CLIENT_SECRET'"
}

run_production() {
  validate_private_config
  require_flutter
  cd "$repository_root"
  flutter run -d linux --debug -t lib/main.dart \
    "--dart-define-from-file=$config_path"
}

build_production() {
  local mode=$1
  validate_private_config
  require_flutter
  cd "$repository_root"
  flutter build linux "--$mode" -t lib/main.dart \
    "--dart-define-from-file=$config_path"
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
    parse_config_option "$@"
    run_production
    ;;
  build)
    [[ $# -ge 1 && ("$1" == debug || "$1" == release) ]] || {
      usage
      exit 2
    }
    mode=$1
    shift
    parse_config_option "$@"
    build_production "$mode"
    ;;
  install)
    [[ $# -ge 2 && ("$1" == debug || "$1" == release) ]] || {
      usage
      exit 2
    }
    mode=$1
    target=$2
    shift 2
    parse_config_option "$@"
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
