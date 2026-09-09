# The RUNPATH step both packagers run on the tree they are about to install
# (#301). Sourced by tool/build_rpm.sh and tool/build_deb.sh so the RPM and the
# DEB cannot differ in it; the work itself is tool/normalize_runpath.py.
#
# Every Flutter plugin library is linked with the RUNPATH of the directory it
# was BUILT in. Shipped as-is that is a search path that exists on no user's
# machine, a leak of the builder's home directory into a file meant for
# distribution, and a lintian `custom-library-search-path` tag on every plugin.
# The step rewrites those to $ORIGIN — where the engine and the other plugins
# actually are, once installed.
#
# Requires the caller to define die().
#
# Usage:  normalize_bundle_runpath /path/to/staged/usr/lib/axiotask
normalize_bundle_runpath() {
  local tree="$1"
  local script="$ROOT/tool/normalize_runpath.py"
  # Loud, never a silent skip: a package built without this step ships the
  # build tree, and nothing downstream would notice until lintian or a user did.
  command -v python3 >/dev/null \
    || die "python3 not found — it is what rewrites the bundled RUNPATHs ($script); refusing to package the build tree's library search paths"
  [ -f "$script" ] || die "missing $script"
  python3 "$script" "$tree" \
    || die "RUNPATH rewrite failed for $tree — see the error above"
}
