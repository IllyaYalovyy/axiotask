#!/usr/bin/env python3
"""Start a built Linux bundle the way a user's machine would and prove that
installation, first start, restart and upgrade keep working.

Usage:
  verify_first_start.py <bundle> [--previous <bundle>]... [--require-oauth-client]
  verify_first_start.py <bundle> --write-fixture <version>

<bundle> is the directory holding the `axiotask` executable: the output of
`flutter build linux`, or `usr/lib/axiotask` of an unpacked RPM or DEB.

This check deliberately imports nothing from the application and reads no
source file. It only knows what a user's disk looks like, so it keeps its
meaning when the code behind the executable changes completely. The release
of 1.5.4 to 1.5.12 replaced the whole code base together with its tests, and
nothing compared the new binary with what users already had: it moved the
data directory, required a hand-written configuration file, lost the built-in
Google client and could not start next to data from an earlier version. Each
scenario below is one of those failures, stated against the binary.

THE CONTRACT. These constants describe users' disks. Changing one means
existing installations lose their data unless the same change ships a
migration and a scenario that proves it.
"""

import argparse
import hashlib
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DATA_DIRECTORY = 'axiotask'          # below $XDG_DATA_HOME or ~/.local/share
CONFIG_DIRECTORY = 'axiotask'        # below $XDG_CONFIG_HOME or ~/.config
DATABASE = 'axiotask.sqlite'
CONFIG_FILE = 'config.json'
DEFAULT_LIST_TITLE = 'My Tasks'

START_TIMEOUT_SECONDS = 30
SETTLE_SECONDS = 3
FIXTURES = Path(__file__).resolve().parent / 'first_start_fixtures'


class Failed(Exception):
    pass


def clean_environment(home, extra=None):
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith('XDG_')
        or key in ('XDG_RUNTIME_DIR', 'XDG_SESSION_TYPE')
    }
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    env.pop('AXIOTASK_PREFIX', None)
    env['HOME'] = str(home)
    env.update(extra or {})
    return env


def data_directory(home, env=None):
    configured = (env or {}).get('XDG_DATA_HOME', '')
    base = Path(configured) if configured else Path(home) / '.local' / 'share'
    return base / DATA_DIRECTORY


def config_directory(home, env=None):
    configured = (env or {}).get('XDG_CONFIG_HOME', '')
    base = Path(configured) if configured else Path(home) / '.config'
    return base / CONFIG_DIRECTORY


def read_database(path):
    """Lists and task titles of a usable database, or None."""
    if not path.exists():
        return None
    try:
        connection = sqlite3.connect(f'file:{path}?mode=ro', uri=True,
                                     timeout=2)
        try:
            if connection.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                return None
            if connection.execute('PRAGMA user_version').fetchone()[0] < 1:
                return None
            lists = dict(connection.execute(
                'SELECT id, title FROM task_lists'))
            tasks = dict(connection.execute('SELECT id, title FROM tasks'))
        finally:
            connection.close()
    except sqlite3.Error:
        return None
    return {'lists': lists, 'tasks': tasks}


def holds_open(session, path):
    """True when a process of the launched session has [path] open.

    Data that is merely left alone is not data the application uses: 1.5.4
    to 1.5.11 left an earlier database untouched and showed "Tasks
    unavailable" instead of the tasks.
    """
    target = os.path.realpath(path)
    for entry in os.listdir('/proc'):
        if not entry.isdigit():
            continue
        try:
            if os.getsid(int(entry)) != session:
                continue
            descriptors = os.listdir(f'/proc/{entry}/fd')
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                if os.readlink(f'/proc/{entry}/fd/{descriptor}') == target:
                    return True
            except OSError:
                continue
    return False


def tail(path, lines=12):
    text = path.read_text(errors='replace') if path.exists() else ''
    return '\n'.join(text.splitlines()[-lines:])


def launch(executable, home, extra_env=None, cwd='/', wait_for_database=True):
    """Runs the app until it has started and settled, then asks it to quit.

    A start that reaches no database within the timeout is a failure, not
    something to retry: a user who sees a frozen window does not retry.
    """
    env = clean_environment(home, extra_env)
    log_path = Path(home) / 'launch.log'
    database = data_directory(home, extra_env) / DATABASE
    with open(log_path, 'ab') as log:
        process = subprocess.Popen(
            ['dbus-run-session', '--', str(executable)],
            env=env, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True)
    try:
        deadline = time.monotonic() + START_TIMEOUT_SECONDS
        while wait_for_database:
            if process.poll() is not None:
                raise Failed(
                    f'the application exited with status {process.returncode}'
                    f' during startup:\n{tail(log_path)}')
            state = read_database(database)
            if state and state['lists'] and holds_open(process.pid, database):
                break
            if time.monotonic() > deadline:
                raise Failed(
                    'the application did not open a task database within '
                    f'{START_TIMEOUT_SECONDS} seconds:\n{tail(log_path)}')
            time.sleep(0.25)
        time.sleep(SETTLE_SECONDS)
        if process.poll() is not None:
            raise Failed(
                f'the application exited with status {process.returncode} '
                f'shortly after starting:\n{tail(log_path)}')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, 15)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, 9)
                process.wait()
                raise Failed('the application did not quit when asked to')


def opened(home, env=None):
    path = data_directory(home, env) / DATABASE
    state = read_database(path)
    if state is None:
        raise Failed(f'no usable database at {path}')
    if not state['lists']:
        raise Failed('the database holds no task list')
    return state


def expect_kept(before, after, what):
    for kind in ('lists', 'tasks'):
        lost = {
            identifier: title for identifier, title in before[kind].items()
            if after[kind].get(identifier) != title
        }
        if lost:
            raise Failed(f'{what} lost or changed {kind}: {lost}')


def digest(directory):
    return {
        str(path.relative_to(directory)):
            hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(Path(directory).rglob('*')) if path.is_file()
    }


def load_fixture(fixture, home, env=None):
    directory = data_directory(home, env)
    directory.mkdir(parents=True)
    connection = sqlite3.connect(directory / DATABASE)
    connection.executescript(fixture.read_text())
    connection.close()
    return opened(home, env)


SYNTHETIC_ROWS = """
INSERT INTO task_lists
  (id, remote_id, title, updated, local_updated, sync_state, pending_op)
VALUES
  ('fixture-list-local', NULL, 'Fixture list never sent to Google',
   '2026-01-02T03:04:05Z', '2026-01-02T03:04:05Z', 'dirty', 'create'),
  ('fixture-list-synced', 'remote-list-1', 'Fixture list from Google',
   '2026-01-02T03:04:05Z', '2026-01-02T03:04:05Z', 'clean', NULL);
INSERT INTO tasks
  (id, remote_id, list_id, parent_id, position, title, notes, status, due,
   updated, local_updated, sync_state, pending_op)
VALUES
  ('fixture-task-local', NULL, 'fixture-list-local', NULL,
   '00000000000000000001', 'Fixture task never sent to Google',
   'Only this device has it.', 'needsAction', '2026-03-04T00:00:00.000Z',
   '2026-01-02T03:04:05Z', '2026-01-02T03:04:05Z', 'dirty', 'create'),
  ('fixture-subtask-local', NULL, 'fixture-list-local', 'fixture-task-local',
   '00000000000000000001', 'Fixture subtask never sent to Google', NULL,
   'needsAction', NULL,
   '2026-01-02T03:04:05Z', '2026-01-02T03:04:05Z', 'dirty', 'create'),
  ('fixture-task-edited', 'remote-task-1', 'fixture-list-synced', NULL,
   '00000000000000000001', 'Fixture task edited on this device', NULL,
   'needsAction', NULL,
   '2026-01-02T03:04:05Z', '2026-01-02T03:04:05Z', 'dirty', 'update'),
  ('fixture-task-done', 'remote-task-2', 'fixture-list-synced', NULL,
   '00000000000000000002', 'Fixture completed task', NULL, 'completed', NULL,
   '2026-01-02T03:04:05Z', '2026-01-02T03:04:05Z', 'clean', NULL);
"""


def write_fixture(executable, version):
    """Records what THIS bundle leaves on disk, with synthetic user data, so
    every later release must prove it still opens it."""
    home = Path(tempfile.mkdtemp(prefix='axiotask-fixture-'))
    try:
        launch(executable, home)
        path = data_directory(home) / DATABASE
        connection = sqlite3.connect(path)
        connection.executescript(SYNTHETIC_ROWS)
        connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        connection.close()
        before = opened(home)
        launch(executable, home)
        expect_kept(before, opened(home), 'the bundle that wrote the fixture')
        connection = sqlite3.connect(path)
        connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        # Both header integers are part of what a release leaves on disk:
        # the application treats a database whose application_id differs
        # from its own schema fingerprint as incompatible and wipes it.
        pragmas = ''.join(
            f'PRAGMA {name} = '
            f'{connection.execute(f"PRAGMA {name}").fetchone()[0]};\n'
            for name in ('user_version', 'application_id'))
        dump = '\n'.join(connection.iterdump())
        connection.close()
        FIXTURES.mkdir(exist_ok=True)
        target = FIXTURES / f'{version}.sql'
        target.write_text(f'{dump}\n{pragmas}')
        print(f'wrote {target}')
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenarios(executable, previous):
    def empty_home(home):
        launch(executable, home)
        state = opened(home)
        if DEFAULT_LIST_TITLE not in state['lists'].values():
            raise Failed(f'no "{DEFAULT_LIST_TITLE}" list on first start: '
                         f'{state["lists"]}')
        if not (config_directory(home) / CONFIG_FILE).exists():
            raise Failed('first start did not create its configuration file')

    def no_setup_needed(home):
        # 1.5.4 to 1.5.10 exited with status 78 until the user wrote a
        # configuration file by hand.
        launch(executable, home)
        opened(home)
        written = set(os.listdir(config_directory(home)))
        if written - {CONFIG_FILE}:
            raise Failed(f'unexpected configuration files: {written}')

    def restarts_keep_data(home):
        launch(executable, home)
        first = opened(home)
        for _ in range(2):
            launch(executable, home)
            state = opened(home)
            expect_kept(first, state, 'a restart')
            if len(state['lists']) != len(first['lists']):
                raise Failed('a restart added task lists: '
                             f'{state["lists"]}')

    def custom_xdg_directories(home):
        env = {
            'XDG_DATA_HOME': str(Path(home) / 'dätä with spaces'),
            'XDG_CONFIG_HOME': str(Path(home) / 'cönfig with spaces'),
        }
        launch(executable, home, env)
        opened(home, env)
        if (Path(home) / '.local' / 'share' / DATA_DIRECTORY).exists():
            raise Failed('XDG_DATA_HOME was ignored')
        if (Path(home) / '.config' / CONFIG_DIRECTORY).exists():
            raise Failed('XDG_CONFIG_HOME was ignored')

    def home_needing_quoting(home):
        nested = Path(home) / 'péople with spaces'
        nested.mkdir()
        launch(executable, nested)
        opened(nested)

    def launched_through_symlink(home):
        link = Path(home) / 'bin' / 'axiotask'
        link.parent.mkdir()
        link.symlink_to(executable)
        launch(link, home, cwd=str(home))
        opened(home)

    def leftovers_of_withdrawn_versions(home):
        # What 1.5.4 to 1.5.12 left behind. It is neither used nor touched.
        other = (Path(home) / '.local' / 'share'
                 / 'io.github.IllyaYalovyy.axiotask')
        other.mkdir(parents=True)
        connection = sqlite3.connect(other / DATABASE)
        connection.executescript(
            'CREATE TABLE accounts (id TEXT PRIMARY KEY);'
            'PRAGMA user_version = 9;')
        connection.close()
        config = config_directory(home)
        config.mkdir(parents=True)
        (config / 'config.toml').write_text('[google]\nclient_id = "x"\n')
        before = digest(other)
        launch(executable, home)
        opened(home)
        if digest(other) != before:
            raise Failed('data of another version was modified')
        if not (config / 'config.toml').exists():
            raise Failed('a configuration file of another version was removed')

    def unreadable_database_is_kept(home):
        directory = data_directory(home)
        directory.mkdir(parents=True)
        content = os.urandom(20000)
        (directory / DATABASE).write_bytes(content)
        launch(executable, home, wait_for_database=False)
        if (directory / DATABASE).read_bytes() != content:
            raise Failed('a database the application could not read was '
                         'overwritten')

    def fixture_scenario(fixture):
        def run(home):
            before = load_fixture(fixture, home)
            launch(executable, home)
            expect_kept(before, opened(home), f'opening {fixture.name}')
            launch(executable, home)
            expect_kept(before, opened(home),
                        f'restarting after {fixture.name}')
        return run

    result = [
        ('first start in an empty home', empty_home),
        ('first start needs no manual setup', no_setup_needed),
        ('restarts keep lists and add none', restarts_keep_data),
        ('custom XDG data and config directories', custom_xdg_directories),
        ('home path with spaces and non-ASCII characters',
         home_needing_quoting),
        ('launched through a symbolic link', launched_through_symlink),
        ('leftovers of the withdrawn 1.5.4-1.5.12 versions',
         leftovers_of_withdrawn_versions),
        ('an unreadable database is never overwritten',
         unreadable_database_is_kept),
    ]
    for fixture in sorted(FIXTURES.glob('*.sql')):
        result.append(
            (f'data written by release {fixture.stem} survives',
             fixture_scenario(fixture)))
    for bundle in previous:
        earlier = Path(bundle).resolve() / 'axiotask'

        def upgrade(home, earlier=earlier):
            try:
                launch(earlier, home)
            except Failed:
                pass  # The earlier release is not the one under test.
            before = read_database(data_directory(home) / DATABASE)
            launch(executable, home)
            after = opened(home)
            if before:
                expect_kept(before, after, f'upgrading from {bundle}')

        result.append((f'upgrade after {bundle} ran here', upgrade))
    return result


def require_oauth_client(executable):
    library = executable.parent / 'lib' / 'libapp.so'
    if not re.search(rb'[0-9]{6,}-[0-9a-z]{20,}\.apps\.googleusercontent\.com',
                     library.read_bytes()):
        raise Failed(
            'no Google client is compiled into the bundle: an installed '
            'package could not sign in without manual configuration')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('bundle')
    parser.add_argument('--previous', action='append', default=[])
    parser.add_argument('--require-oauth-client', action='store_true',
                        help='for release builds: sign-in must work as '
                             'installed')
    parser.add_argument('--write-fixture', metavar='VERSION')
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
        sys.exit('A display is required (use xvfb-run on a headless machine)')

    if arguments.write_fixture:
        write_fixture(executable, arguments.write_fixture)
        return

    failed = 0
    checks = scenarios(executable, arguments.previous)
    if arguments.require_oauth_client:
        checks.insert(0, ('a Google client is compiled in',
                          lambda home: require_oauth_client(executable)))
    for name, scenario in checks:
        home = Path(tempfile.mkdtemp(prefix='axiotask-first-start-'))
        try:
            scenario(home)
        except Failed as failure:
            failed += 1
            print(f'FAIL  {name}\n      {failure}', flush=True)
            if arguments.keep:
                print(f'      kept {home}', flush=True)
                continue
        else:
            print(f'ok    {name}', flush=True)
        shutil.rmtree(home, ignore_errors=True)
    if failed:
        sys.exit(f'{failed} first-start scenario(s) failed')
    print(f'First start verified: {len(checks)} scenarios.')


if __name__ == '__main__':
    main()
