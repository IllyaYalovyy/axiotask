#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
version, build = next(x.split()[1] for x in pathlib.Path('pubspec.yaml').read_text().splitlines() if x.startswith('version:')).split('+')
names = [f'axiotask-{version}-{build}.x86_64.rpm', f'axiotask_{version}-{build}_amd64.deb', f'axiotask-{version}.flatpak', f'axiotask-{version}.apk', 'ANDROID_SIGNING_CERT.txt']
for name in names: (root / name).write_text('fixture')
(root / 'SHA256SUMS').write_text(''.join('0' * 64 + '  ' + name + '\n' for name in names))
def check(ok):
    result = subprocess.run([sys.executable, 'scripts/check_release_assets.py', str(root)], capture_output=True)
    assert (result.returncode == 0) == ok, result.stderr.decode()
check(True)
for name in names:
    (root / name).unlink()
    check(False)
    (root / name).write_text('fixture')
(root / 'app-debug.apk').write_text('fixture')
check(False)
(root / 'app-debug.apk').unlink()
(root / 'SHA256SUMS').write_text('0' * 64 + '  ' + names[0] + '\n')
check(False)
print('Release artifact contract: passed')
PY
