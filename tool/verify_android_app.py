#!/usr/bin/env python3
"""Install an APK on a connected Android device or emulator and use it the
way a person does, through the labels on the screen.

Usage:
  verify_android_app.py --apk <candidate.apk> [--previous-apk <released.apk>]
                        [--serial <adb serial>] [--artifacts <directory>]

The device must be disposable (an emulator, or a phone with no Axiotask data
worth keeping): the application is uninstalled first.

Like tool/verify_first_start.py, this check reads no source file and imports
nothing from the application. It knows only what is on the screen, so it keeps
its meaning when the code behind the APK changes. 1.5.4 to 1.5.12 replaced
the code together with its tests; an audit against 1.5.3 then found 21 of 36
everyday phone actions missing or broken (swipes, Undo, the add button,
Duplicate, Export, Previous/Next, the smart-view tabs, ...), and several
screens gone (About, Account, sync settings). Every one of those is a label
or a gesture below.

tool/android_surface.json is the inventory of controls a release offers. A
control may be added freely. Removing or renaming one fails this check until
the inventory is changed in the same commit, which makes the removal a
visible, reviewable decision instead of an accident.

Everything runs signed out and offline-capable: no Google account is used.
"""

import argparse
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = 'com.axiotask.app'
SURFACE = Path(__file__).resolve().parent / 'android_surface.json'
START_TIMEOUT_SECONDS = 90
WAIT_SECONDS = 20


class Failed(Exception):
    pass


class Device:
    def __init__(self, serial, artifacts):
        self.prefix = ['adb'] + (['-s', serial] if serial else [])
        self.artifacts = artifacts

    def adb(self, *arguments, check=True, binary=False, timeout=180):
        result = subprocess.run(
            self.prefix + list(arguments), capture_output=True,
            timeout=timeout)
        if check and result.returncode != 0:
            raise Failed(
                f'adb {" ".join(arguments)} failed: '
                f'{result.stderr.decode(errors="replace").strip()}'
                f'{result.stdout.decode(errors="replace").strip()}')
        return result.stdout if binary else result.stdout.decode(
            errors='replace')

    def nodes(self):
        """(label, left, top, right, bottom) of every labelled node of the
        application currently on screen."""
        for _ in range(6):
            raw = self.adb('exec-out', 'uiautomator', 'dump', '/dev/tty',
                           check=False)
            start, end = raw.find('<?xml'), raw.rfind('</hierarchy>')
            if start >= 0 and end >= 0:
                root = ET.fromstring(raw[start:end + len('</hierarchy>')])
                if self._dismiss_system_dialog(root):
                    continue
                found = []
                for node in root.iter('node'):
                    if node.get('package') != PACKAGE:
                        continue
                    label = node.get('content-desc') or node.get('text') or ''
                    if label:
                        bounds = tuple(map(int, re.findall(
                            r'\d+', node.get('bounds'))))
                        found.append((label,) + bounds)
                return found
            time.sleep(1)
        raise Failed('the screen could not be read')

    def _dismiss_system_dialog(self, root):
        """A slow emulator shows "<some system app> isn't responding" over
        the application. That dialog is the device's, not the candidate's:
        choose Wait and look again. The candidate's own ANR is not excused,
        because its dialog names the application and is reported below."""
        for node in root.iter('node'):
            if node.get('resource-id') != 'android:id/aerr_wait':
                continue
            title = ' '.join(
                other.get('text') or '' for other in root.iter('node'))
            if 'axiotask' in title.lower():
                raise Failed(f'the application stopped responding: {title}')
            bounds = list(map(int, re.findall(r'\d+', node.get('bounds'))))
            self.adb('shell', 'input', 'tap',
                     str((bounds[0] + bounds[2]) // 2),
                     str((bounds[1] + bounds[3]) // 2))
            time.sleep(2)
            return True
        return False

    def labels(self):
        return [node[0] for node in self.nodes()]

    def find(self, label):
        """Nodes whose label, or its first line, is [label]. A trailing `*`
        matches a prefix; a leading `=` matches the whole label only."""
        if label.startswith('='):
            return [n for n in self.nodes() if n[0] == label[1:]]
        if label.endswith('*'):
            return [n for n in self.nodes() if n[0].startswith(label[:-1])]
        return [n for n in self.nodes()
                if n[0] == label or n[0].split('\n')[0] == label]

    def wait(self, label, seconds=WAIT_SECONDS, gone=False):
        deadline = time.monotonic() + seconds
        while True:
            matches = self.find(label)
            if bool(matches) != gone:
                return matches
            if time.monotonic() > deadline:
                self.capture('failure')
                state = 'still shown' if gone else 'not shown'
                raise Failed(
                    f'"{label}" is {state}. On screen: '
                    f'{[text.splitlines()[0] for text in self.labels()]}')
            time.sleep(0.5)

    def tap(self, label, index=0):
        node = self.wait(label)[index]
        self.adb('shell', 'input', 'tap',
                 str((node[1] + node[3]) // 2), str((node[2] + node[4]) // 2))
        time.sleep(1)

    def long_press(self, label):
        node = self.wait(label)[0]
        x, y = (node[1] + node[3]) // 2, (node[2] + node[4]) // 2
        self.adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y),
                 '900')
        time.sleep(1)

    def swipe(self, label, direction):
        node = self.wait(label)[0]
        y = (node[2] + node[4]) // 2
        width = node[3] - node[1]
        near, far = node[1] + width // 5, node[1] + width * 4 // 5
        start, end = (near, far) if direction == 'right' else (far, near)
        self.adb('shell', 'input', 'swipe', str(start), str(y), str(end),
                 str(y), '250')
        time.sleep(1.5)

    def scroll(self, direction):
        """Moves the content of the screen by about a third of its height."""
        if not hasattr(self, 'size'):
            self.size = tuple(map(int, re.findall(
                r'\d+', self.adb('shell', 'wm', 'size').splitlines()[-1])))
        width, height = self.size
        low, high = height * 2 // 3, height // 3
        start, end = (low, high) if direction == 'down' else (high, low)
        self.adb('shell', 'input', 'swipe', str(width // 2), str(start),
                 str(width // 2), str(end), '400')
        time.sleep(1)

    def type(self, text):
        self.adb('shell', 'input', 'text', text.replace(' ', '%s'))
        time.sleep(0.5)

    def key(self, name):
        self.adb('shell', 'input', 'keyevent', name)
        time.sleep(1)

    def back(self):
        self.key('KEYCODE_BACK')

    def capture(self, name):
        if self.artifacts:
            self.artifacts.mkdir(parents=True, exist_ok=True)
            (self.artifacts / f'{name}.png').write_bytes(
                self.adb('exec-out', 'screencap', '-p', binary=True,
                         check=False))

    def launch(self):
        self.adb('shell', 'monkey', '-p', PACKAGE, '-c',
                 'android.intent.category.LAUNCHER', '1')

    def stop(self):
        self.adb('shell', 'am', 'force-stop', PACKAGE)
        time.sleep(1)

    def installed_version(self):
        text = self.adb('shell', 'dumpsys', 'package', PACKAGE)
        match = re.search(r'versionName=(\S+)', text)
        return match.group(1) if match else None


def start(device):
    """Launches the application and returns once its task list is usable."""
    device.launch()
    deadline = time.monotonic() + START_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        labels = device.labels()
        if 'Start using axiotask' in labels:
            device.tap('Start using axiotask')
            continue
        if 'New task' in labels:
            # Always work in the view that shows every task.
            device.tap('All Tasks\nTab*')
            return
        time.sleep(1)
    device.capture('failure')
    raise Failed('the task list did not appear within '
                 f'{START_TIMEOUT_SECONDS} seconds. On screen: '
                 f'{device.labels()}')


def expect_surface(device, screen, surface):
    """Every control of [screen] is offered, scrolling when the screen is
    too small to show them at once."""
    def missing_from(first_lines):
        return [
            label for label in surface[screen]
            if not (label in first_lines
                    or (label.endswith('*')
                        and any(line.startswith(label[:-1])
                                for line in first_lines)))
        ]

    seen = {label.split('\n')[0] for label in device.labels()}
    missing = missing_from(seen)
    scrolled = 0
    while missing and scrolled < 4:
        device.scroll('down')
        scrolled += 1
        seen |= {label.split('\n')[0] for label in device.labels()}
        missing = missing_from(seen)
    for _ in range(scrolled):
        device.scroll('up')
    if missing:
        device.capture(f'missing-{screen}')
        raise Failed(
            f'the {screen} screen no longer offers {missing}. A control that '
            'a release offered may only disappear together with a change to '
            'tool/android_surface.json.')


def checks(surface, version):
    task = 'Guard task one'
    row = f'{task}\n*'       # the row: title, sync state and list
    checkbox = f'={task}'     # its checkbox carries the bare title

    def first_start(device):
        expect_surface(device, 'home', surface)

    def controls_of_every_screen(device):
        device.tap('More list actions')
        expect_surface(device, 'list menu', surface)
        device.back()
        device.tap('Sort order')
        expect_surface(device, 'sort menu', surface)
        device.back()
        device.tap('Open navigation menu')
        expect_surface(device, 'navigation', surface)
        for _ in range(4):
            if device.find('Properties'):
                break
            device.scroll('down')  # the drawer's footer on a short screen
        device.tap('Properties')
        expect_surface(device, 'properties: sync', surface)
        previous = 'Sync'
        for tab in ('Appearance', 'Account', 'About'):
            if not device.find(tab):
                device.swipe(previous, 'left')  # a narrow tab bar scrolls
            device.tap(tab)
            previous = tab
            expect_surface(device, f'properties: {tab.lower()}', surface)
        shown = [label for label in device.labels()
                 if label.startswith('Version')]
        if shown != [f'Version\nv{version}']:
            raise Failed(f'About shows {shown}, the package is {version}')
        device.tap('Close')
        device.wait('New task')

    def capture_a_task(device):
        device.tap('New task')
        expect_surface(device, 'composer', surface)
        device.type(task)
        device.key('KEYCODE_ENTER')
        # On a short screen the keyboard covers the list while composing.
        device.tap('Close the composer')
        device.wait('New task')
        device.wait(row)

    def task_survives_restart(device):
        device.stop()
        start(device)
        device.wait(row)

    def details_and_duplicate(device):
        device.tap(row)
        expect_surface(device, 'task details', surface)
        device.tap('More actions')
        expect_surface(device, 'task actions', surface)
        device.tap('Duplicate')
        device.back()
        device.wait('New task')
        device.wait(f'{task} (copy)*')
        device.wait(row)

    def complete_and_undo(device):
        device.tap(checkbox)
        # Undo is offered only briefly, so it is taken before anything else
        # is inspected; that it was offered is proven by the tap finding it.
        device.tap('Undo')
        device.wait(row)

    def swipe_right_completes(device):
        device.swipe(row, 'right')
        device.tap('Undo')
        device.wait(row)
        # Without Undo the swiped task leaves the open tasks.
        device.swipe(row, 'right')
        device.wait(row, gone=True)
        device.tap('Undo')
        device.wait(row)

    def swipe_left_schedules(device):
        device.swipe(row, 'left')
        expect_surface(device, 'quick dates', surface)
        device.tap('Tomorrow')
        device.wait('Pick a date…', gone=True)
        device.wait('New task')

    def long_press_selects(device):
        device.long_press(row)
        expect_surface(device, 'selection', surface)
        device.tap('Clear selection')
        device.wait('Clear selection', gone=True)

    def export_sheet(device):
        device.tap('More list actions')
        device.tap('Export view…')
        expect_surface(device, 'export', surface)
        device.tap('Cancel')
        device.wait('New task')

    def everything_survives_restart(device):
        before = len(device.find(row))
        device.stop()
        start(device)
        if len(device.wait(row)) != before:
            raise Failed('tasks were lost across a restart')

    return [
        ('first start shows a usable task list', first_start),
        ('every screen still offers its controls and the right version',
         controls_of_every_screen),
        ('a task can be captured', capture_a_task),
        ('the task survives a restart', task_survives_restart),
        ('details, and Duplicate', details_and_duplicate),
        ('completion and Undo', complete_and_undo),
        ('swiping right completes, with Undo', swipe_right_completes),
        ('swiping left offers quick dates', swipe_left_schedules),
        ('a long press starts selection with bulk actions',
         long_press_selects),
        ('the export sheet', export_sheet),
        ('all tasks survive a restart', everything_survives_restart),
    ]


def install(device, apk, previous):
    device.adb('uninstall', PACKAGE, check=False)
    if previous:
        device.adb('install', str(previous), timeout=600)
        earlier = device.installed_version()
        device.launch()
        time.sleep(15)  # Let the earlier release write whatever it writes.
        device.stop()
        output = device.adb('install', '-r', str(apk), check=False,
                            timeout=600)
        if 'Success' not in output:
            raise Failed(
                f'the candidate cannot be installed over {earlier}: '
                f'{output.strip() or "installation was refused"}. Existing '
                'users would have to uninstall and lose local data.')
        return f'installed over {earlier}'
    device.adb('install', str(apk), timeout=600)
    return 'installed on a clean device'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--apk', required=True)
    parser.add_argument('--previous-apk')
    parser.add_argument('--serial')
    parser.add_argument('--artifacts')
    arguments = parser.parse_args()

    surface = json.loads(SURFACE.read_text())
    device = Device(arguments.serial,
                    Path(arguments.artifacts) if arguments.artifacts else None)
    failed = 0
    try:
        how = install(device, arguments.apk, arguments.previous_apk)
        version = device.installed_version()
        print(f'ok    {version} {how}', flush=True)
        start(device)
    except Failed as failure:
        sys.exit(f'FAIL  installation and first start\n      {failure}')

    for name, check in checks(surface, version):
        try:
            check(device)
        except Failed as failure:
            failed += 1
            print(f'FAIL  {name}\n      {failure}', flush=True)
            # Return to a known screen so one failure does not cascade.
            device.stop()
            try:
                start(device)
            except Failed as restart:
                sys.exit(f'FAIL  the application no longer starts\n'
                         f'      {restart}')
        else:
            print(f'ok    {name}', flush=True)
    if failed:
        sys.exit(f'{failed} Android check(s) failed')
    print('Android application verified.')


if __name__ == '__main__':
    main()
