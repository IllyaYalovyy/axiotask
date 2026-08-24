#!/usr/bin/env bash
# The desktop OAuth client credentials, compiled into the build (#229) — the ONE
# place that decides whether a build carries them.
#
# A packaged install has to sync out of the box; asking someone who installed an
# RPM to create a Google Cloud project and hand-edit config.json before their
# first sign-in is not a shippable first run. Google's installed-app model makes
# bundling the right answer rather than a leak: the id and secret of a "Desktop
# app" client are NOT confidential — they ship inside every installed copy of
# every such app, and the flow is protected by PKCE plus the loopback redirect,
# not by the secret.
#
# Compiled in, never committed. The values live in
#
#     tool/oauth_credentials.json        <- GITIGNORED, created by the operator
#     { "AXIOTASK_GOOGLE_CLIENT_ID": "...", "AXIOTASK_GOOGLE_CLIENT_SECRET": "..." }
#
# and reach the app through --dart-define-from-file. A checkout that has no such
# file builds exactly the app we built before #229: nothing is compiled in, and
# config.json is the only source (see lib/src/app/google_credentials.dart, which
# also lets a filled-in config.json override the bundled default).
#
# Usage — sourced by tool/install.sh, tool/build_rpm.sh and tool/dev.sh:
#
#     source "$ROOT/tool/oauth_defines.sh"
#     oauth_define_args                                  # fills OAUTH_DEFINES
#     flutter build linux --release ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"}
#
# Usage — executed, which is how the packaging test observes the decision
# without running a Flutter build:
#
#     bash tool/oauth_defines.sh          # prints the argument, or nothing
#
# $AXIOTASK_OAUTH_DEFINES points a build at a different credentials file (a beta
# client; a throwaway one under test).
#
# DESKTOP ONLY. Android has no client credentials at all — Play Services
# identifies the app by package name + signing-certificate SHA-1 (RFC-010) — so
# an APK build must never be given this file: it would compile a secret into the
# app that nothing there can use. No script here builds an APK, and that is why.

_oauth_defines_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The credentials file this build would use — existing or not.
oauth_defines_file() {
  printf '%s' \
    "${AXIOTASK_OAUTH_DEFINES:-$_oauth_defines_root/tool/oauth_credentials.json}"
}

# Fill OAUTH_DEFINES with the flutter argument, or leave it EMPTY when there is
# no credentials file. A missing file is never an error: it is the ordinary
# state of a fresh clone, and the resulting build simply falls back to
# config.json the way it always did.
oauth_define_args() {
  OAUTH_DEFINES=()
  local file
  file="$(oauth_defines_file)"
  if [ -f "$file" ]; then
    OAUTH_DEFINES+=("--dart-define-from-file=$file")
  fi
  return 0
}

# One line saying WHETHER this build carries credentials — never what they are.
# Build output gets pasted into issues and CI logs.
oauth_defines_report() {
  local file
  file="$(oauth_defines_file)"
  if [ -f "$file" ]; then
    printf 'OAuth credentials bundled from %s\n' "$file"
  else
    printf 'no OAuth credentials file at %s — this build can only sign in once config.json is filled in (see README)\n' \
      "$file"
  fi
}

# Executed rather than sourced: print the argument, one per line, nothing at all
# when there is no credentials file.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  oauth_define_args
  for _oauth_arg in ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"}; do
    printf '%s\n' "$_oauth_arg"
  done
fi
