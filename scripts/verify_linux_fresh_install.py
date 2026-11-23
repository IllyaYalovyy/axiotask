#!/usr/bin/env python3
"""Start a built Linux bundle in disposable home directories and prove that
it opens its task database in every state a new installation can meet.

Usage: verify_linux_fresh_install.py <bundle-directory> [--previous <bundle>]...

The bundle is the directory `flutter build linux` or a package stage produces
(the one holding the `axiotask` executable). Each `--previous` bundle is an
earlier release that is run first in its own home, after which the bundle
under test must open what that release left behind.

Every launch gets its own HOME and its own D-Bus session, so the developer's
data, keyring and any running Axiotask are never touched. A display is needed.

The verdict comes from what the application itself persists: the database it
creates and the failure records in its diagnostics file. `--expect-failure`
inverts the legacy scenario and is the control that proves the check can fail.
"""

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

APPLICATION_ID = 'io.github.IllyaYalovyy.axiotask'
DATABASE = 'axiotask.sqlite'
DIAGNOSTICS = 'axiotask-diagnostics-safe.json'
START_TIMEOUT_SECONDS = 30
STALL_ATTEMPTS = 4
SETTLE_SECONDS = 3


class Failed(Exception):
    pass


class Stalled(Failed):
    """The process stopped making progress before reaching any verdict.

    This is the Flutter engine freezing its main thread during the first
    window layout on Wayland, which happens in a fraction of launches and is
    unrelated to where data is stored. Such a launch proves nothing either
    way, so the scenario is repeated; every stall is still reported.
    """


def launch(executable, home, extra_env=None, cwd='/', expect_exit=None):
    """Runs the app until it has settled, then stops it. Returns its log."""
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith('XDG_') or key in ('XDG_RUNTIME_DIR',
                                                 'XDG_SESSION_TYPE')
    }
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    env['HOME'] = str(home)
    env.update(extra_env or {})
    log_path = Path(home) / 'launch.log'
    with open(log_path, 'ab') as log:
        process = subprocess.Popen(
            ['dbus-run-session', '--', str(executable)],
            env=env, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True)
    try:
        if expect_exit is not None:
            try:
                code = process.wait(timeout=START_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                raise Failed(f'expected exit status {expect_exit}, '
                             'but the application kept running')
            if code != expect_exit:
                raise Failed(f'expected exit status {expect_exit}, got {code}')
            return log_path.read_text(errors='replace')
        data = data_directories(home, env)
        deadline = time.monotonic() + START_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise Failed(
                    f'the application exited with status {process.returncode}'
                    f' during startup:\n{tail(log_path)}')
            if any(outcome_known(directory) for directory in data):
                break
            time.sleep(0.25)
        else:
            raise Stalled('the application neither opened a database nor '
                          f'recorded a failure:\n{tail(log_path)}')
        time.sleep(SETTLE_SECONDS)
        if process.poll() is not None:
            raise Failed(
                f'the application exited with status {process.returncode} '
                f'after startup:\n{tail(log_path)}')
        return log_path.read_text(errors='replace')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, 15)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, 9)
                process.wait()


def run_earlier_release(executable, home):
    """Lets an earlier release leave whatever it leaves. It is not under
    test: releases before v1.5.11 exit when no configuration exists."""
    try:
        launch(executable, home)
    except Failed:
        pass


def tail(path, lines=15):
    return '\n'.join(path.read_text(errors='replace').splitlines()[-lines:])


def data_home(home, env):
    configured = (env or {}).get('XDG_DATA_HOME', '')
    if configured.startswith('/'):
        return Path(configured)
    return Path(home) / '.local' / 'share'


def data_directories(home, env=None):
    base = data_home(home, env)
    return [base / APPLICATION_ID, base / 'axiotask']


def failure_records(directory):
    path = directory / DIAGNOSTICS
    if not path.exists():
        return []
    try:
        records = json.loads(path.read_text())['records']
    except (ValueError, KeyError):
        return []
    return [record for record in records if record.get('kind') == 'failure']


def outcome_known(directory):
    return bool(failure_records(directory)) or (
        (directory / DATABASE).exists()
        and (directory / DIAGNOSTICS).exists()
        and database_ready(directory / DATABASE))


def database_ready(path):
    """True once the schema is complete: the version is written last."""
    try:
        connection = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
        try:
            tables = {row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'")}
            version = connection.execute('PRAGMA user_version').fetchone()[0]
            check = connection.execute('PRAGMA quick_check').fetchone()[0]
        finally:
            connection.close()
    except sqlite3.Error:
        return False
    return 'accounts' in tables and version >= 1 and check == 'ok'


def all_failure_records(home, env=None):
    own, legacy = data_directories(home, env)
    return failure_records(own) + failure_records(legacy)


def expect_opened(home, env=None, earlier=()):
    """The app under test opened a usable database in its own directory.

    [earlier] holds the failures an earlier release had already recorded.
    """
    own, _ = data_directories(home, env)
    failures = [record for record in all_failure_records(home, env)
                if record not in earlier]
    if failures:
        raise Failed('the application recorded failures: '
                     + json.dumps(failures))
    if not database_ready(own / DATABASE):
        raise Failed(f'no usable database at {own / DATABASE}')


def digest(directory):
    result = {}
    for path in sorted(Path(directory).rglob('*')):
        if path.is_file():
            result[str(path.relative_to(directory))] = hashlib.sha256(
                path.read_bytes()).hexdigest()
    return result


def seed_v153(home, env=None):
    """What v1.5.3 and earlier left behind: a directory named after the
    executable holding an incompatible database of the same file name."""
    legacy = data_home(home, env) / 'axiotask'
    legacy.mkdir(parents=True)
    connection = sqlite3.connect(legacy / DATABASE)
    connection.executescript(
        'CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT);'
        "INSERT INTO tasks VALUES ('1', 'left by v1.5.3');"
        'PRAGMA user_version = 1;')
    connection.close()
    (legacy / 'tokens.json').write_text('{"synthetic": true}')
    (legacy / 'prefs.json').write_text('{}')
    config = Path(home) / '.config' / 'axiotask'
    config.mkdir(parents=True)
    (config / 'config.json').write_text('{"synthetic": true}')
    return legacy


def write_config(home, text):
    directory = Path(home) / '.config' / 'axiotask'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'config.toml').write_text(text)


def scenarios(executable, previous, expect_failure):
    def empty_home(home):
        launch(executable, home)
        expect_opened(home)
        if (data_home(home, None) / 'axiotask').exists():
            raise Failed('a directory named after the executable was created')

    def relaunch(home):
        for _ in range(3):
            launch(executable, home)
            expect_opened(home)

    def leftover_v153(home):
        legacy = seed_v153(home)
        before = digest(legacy)
        launch(executable, home)
        expect_opened(home)
        if digest(legacy) != before:
            raise Failed('the data left by v1.5.3 was modified')

    def leftover_v153_custom_data_home(home):
        env = {'XDG_DATA_HOME': str(Path(home) / 'custom data')}
        legacy = seed_v153(home, env)
        before = digest(legacy)
        launch(executable, home, env)
        expect_opened(home, env)
        if digest(legacy) != before:
            raise Failed('the data left by v1.5.3 was modified')
        if (Path(home) / '.local' / 'share' / APPLICATION_ID).exists():
            raise Failed('XDG_DATA_HOME was ignored')

    def relative_data_home(home):
        launch(executable, home, {'XDG_DATA_HOME': 'relative'})
        expect_opened(home)

    def home_needing_quoting(home):
        nested = Path(home) / 'péople with spaces'
        nested.mkdir()
        launch(executable, nested)
        expect_opened(nested)

    def empty_directories_present(home):
        (Path(home) / '.local' / 'share' / APPLICATION_ID).mkdir(parents=True)
        (Path(home) / '.config' / 'axiotask').mkdir(parents=True)
        launch(executable, home)
        expect_opened(home)

    def launched_through_symlink(home):
        link = Path(home) / 'bin' / 'axiotask'
        link.parent.mkdir()
        link.symlink_to(executable)
        launch(link, home, cwd=str(home))
        expect_opened(home)

    def configured(home):
        write_config(
            home,
            '[google]\n'
            'client_id = "synthetic.apps.googleusercontent.com"\n'
            'client_secret = "synthetic"\n')
        launch(executable, home)
        expect_opened(home)

    def invalid_config_stops_startup(home):
        write_config(home, 'not = [valid')
        log = launch(executable, home, expect_exit=78)
        if 'Axiotask configuration error' not in log:
            raise Failed('an invalid configuration was not diagnosed')

    def control(home):
        seed_v153(home)
        launch(executable, home)
        try:
            expect_opened(home)
        except Failed:
            return
        raise Failed('the control bundle opened a database')

    if expect_failure:
        return [('control: leftover v1.5.3 data stops this bundle', control)]

    result = [
        ('empty home directory', empty_home),
        ('three consecutive launches', relaunch),
        ('leftover v1.5.3 data and configuration', leftover_v153),
        ('leftover v1.5.3 data below a custom XDG_DATA_HOME',
         leftover_v153_custom_data_home),
        ('relative XDG_DATA_HOME is ignored', relative_data_home),
        ('home path with spaces and non-ASCII characters',
         home_needing_quoting),
        ('empty data and configuration directories already present',
         empty_directories_present),
        ('launched through a symbolic link', launched_through_symlink),
        ('configuration file present', configured),
        ('invalid configuration stops startup with status 78',
         invalid_config_stops_startup),
    ]
    for bundle in previous:
        earlier = Path(bundle).resolve() / 'axiotask'

        def upgrade(home, earlier=earlier):
            run_earlier_release(earlier, home)
            recorded = all_failure_records(home)
            launch(executable, home)
            expect_opened(home, earlier=recorded)

        def upgrade_over_v153(home, earlier=earlier):
            seed_v153(home)
            run_earlier_release(earlier, home)
            recorded = all_failure_records(home)
            launch(executable, home)
            expect_opened(home, earlier=recorded)

        result.append((f'after {bundle} ran in an empty home', upgrade))
        result.append((f'after {bundle} ran over v1.5.3 data',
                       upgrade_over_v153))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('bundle')
    parser.add_argument('--previous', action='append', default=[])
    parser.add_argument('--expect-failure', action='store_true')
    parser.add_argument('--keep', action='store_true',
                        help='keep the home directories of failed scenarios')
    arguments = parser.parse_args()

    executable = Path(arguments.bundle).resolve() / 'axiotask'
    for path in [executable] + [
            Path(bundle).resolve() / 'axiotask'
            for bundle in arguments.previous]:
        if not (path.is_file() and os.access(path, os.X_OK)):
            sys.exit(f'No executable at {path}')
    if shutil.which('dbus-run-session') is None:
        sys.exit("Required command 'dbus-run-session' is unavailable")
    if not (os.environ.get('WAYLAND_DISPLAY') or os.environ.get('DISPLAY')):
        sys.exit('A display is required')

    failed = 0
    stalls = 0
    for name, scenario in scenarios(
            executable, arguments.previous, arguments.expect_failure):
        for attempt in range(STALL_ATTEMPTS):
            home = Path(tempfile.mkdtemp(prefix='axiotask-fresh-install-'))
            try:
                scenario(home)
            except Stalled as stall:
                stalls += 1
                print(f'stall {name}', flush=True)
                shutil.rmtree(home, ignore_errors=True)
                if attempt + 1 < STALL_ATTEMPTS:
                    continue
                failed += 1
                print(f'FAIL  {name}\n      {stall}', flush=True)
            except Failed as failure:
                failed += 1
                print(f'FAIL  {name}\n      {failure}', flush=True)
                if arguments.keep:
                    print(f'      kept {home}', flush=True)
                else:
                    shutil.rmtree(home, ignore_errors=True)
            else:
                print(f'ok    {name}', flush=True)
                shutil.rmtree(home, ignore_errors=True)
            break
    if stalls:
        print(f'{stalls} launch(es) froze during startup and were repeated.')
    if failed:
        sys.exit(f'{failed} fresh-install scenario(s) failed')
    print('Fresh installation verified.')


if __name__ == '__main__':
    main()
