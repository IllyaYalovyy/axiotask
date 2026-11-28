"""Check a ktask change against the commit the supervisor started from."""

import os
import re
import subprocess
from pathlib import Path


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def version(manifest):
    match = re.search(r'^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$', manifest, re.M)
    if not match:
        raise SystemExit('Expected version: X.Y.Z+B in pubspec.yaml')
    return tuple(map(int, match.groups()))


def main():
    base = os.environ.get('KTASK_BASE_COMMIT', 'HEAD')
    previous = version(git('show', f'{base}:pubspec.yaml'))
    current = version(Path('pubspec.yaml').read_text())
    changed = git('diff', '--name-only', base) or git(
        'ls-files', '--others', '--exclude-standard')
    if changed and (current[:3] <= previous[:3] or current[3] <= previous[3]):
        raise SystemExit('Every task change must increase both the app version '
                         'and the build number relative to its base commit.')
    release = '.'.join(map(str, current[:3]))
    about = Path('lib/src/app/app_version.dart').read_text()
    if f"const String appVersion = '{release}';" not in about:
        raise SystemExit('Update appVersion to match pubspec.yaml.')
    subprocess.run(['bash', 'tool/release_guard.sh', f'v{release}'], check=True)


if __name__ == '__main__':
    main()
