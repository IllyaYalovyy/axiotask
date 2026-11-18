#!/usr/bin/env python3
"""Run reviewed UI steps against an exact signed APK on an isolated Android target.

The scenario uses accessibility labels, not screen coordinates. Screenshots
require a separate human comparison review before the release guard accepts
this evidence. This command never clears or replaces an existing installation.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import time
import xml.etree.ElementTree as ET

from check_android_qualification import CERTIFICATE, SMOKE_CHECKS, require

FLOWS = ('menu', 'capture_edit_persistence', 'completion_undo', 'navigation')


def validate_scenario(scenario):
    require(set(scenario) == set(FLOWS), 'Scenario must cover all four workflows')
    for name, steps in scenario.items():
        require(isinstance(steps, list) and steps, f'Missing steps: {name}')
        require(any(step.get('action') == 'expect' for step in steps),
                f'{name} must assert an observable outcome')
        for step in steps:
            require(step.get('action') in {'tap', 'expect', 'text', 'back', 'relaunch'},
                    'Unknown smoke action')
            if step['action'] in {'tap', 'expect'}:
                require(isinstance(step.get('label'), str) and step['label'], 'Missing label')
            if step['action'] == 'text':
                require(re.fullmatch(r'[A-Za-z0-9 ._@-]+', step.get('value', '')),
                        'Smoke input must be safe synthetic ASCII text')
    require(any(step['action'] == 'relaunch' for step in scenario['capture_edit_persistence']),
            'Capture/edit persistence must be asserted after relaunch')
    persistence = scenario['capture_edit_persistence']
    last_restart = max(i for i, step in enumerate(persistence) if step['action'] == 'relaunch')
    require(any(step['action'] == 'expect' for step in persistence[last_restart + 1:]),
            'Missing post-relaunch persistence assertion')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('apk', 'commit', 'device', 'scenario', 'artifacts', 'apksigner', 'apkanalyzer'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--isolated-target', action='store_true', required=True,
                        help='Confirm this target is dedicated to synthetic qualification')
    args = parser.parse_args()
    root = pathlib.Path(args.artifacts).resolve()
    require(not root.exists(), 'Evidence directory must be new')
    scenario = json.loads(pathlib.Path(args.scenario).read_text())
    validate_scenario(scenario)
    require(re.fullmatch(r'[0-9a-f]{40}', args.commit), 'Invalid source commit')
    apk = pathlib.Path(args.apk).resolve()
    report = subprocess.check_output([args.apksigner, 'verify', '--print-certs', str(apk)], text=True)
    require({s.lower() for s in re.findall(r'certificate SHA-256 digest: ([0-9a-fA-F]{64})', report)}
            == {CERTIFICATE}, 'Unrecognized APK signer')
    package = 'com.axiotask.app'
    for field, expected in [('application-id', package), ('debuggable', 'false')]:
        require(subprocess.check_output([args.apkanalyzer, 'manifest', field, str(apk)],
                                        text=True).strip() == expected, 'APK identity mismatch')

    def adb(*command, binary=False):
        return subprocess.check_output([args.adb, '-s', args.device, *command],
                                       text=not binary, timeout=60)

    def prop(name):
        return adb('shell', 'getprop', name).strip()

    require(adb('get-state').strip() == 'device', 'Target is not connected')
    installed = subprocess.run([args.adb, '-s', args.device, 'shell', 'pm', 'path', package],
                               capture_output=True, text=True, timeout=60)
    require(installed.returncode in (0, 1) and not installed.stdout.strip(),
            'Existing installation found; use a dedicated empty target')
    emulator = prop('ro.kernel.qemu') == '1' or args.device.startswith('emulator-')
    evidence = {'schema_version': 1, 'source_commit': args.commit,
                'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                'application_id': package, 'signing_certificate_sha256': CERTIFICATE,
                'debuggable': False,
                'execution_mode': 'signed-release-emulator' if emulator else 'signed-release-physical',
                'device': {'kind': 'emulator' if emulator else 'physical', 'serial': args.device,
                           'model': prop('ro.product.model'), 'api': int(prop('ro.build.version.sdk'))},
                'checks': dict.fromkeys(SMOKE_CHECKS, False), 'reviewed_by': '', 'screenshots': []}
    root.mkdir(parents=True)
    (root / 'scenario.json').write_text(json.dumps(scenario, indent=2) + '\n')

    def launch():
        adb('shell', 'am', 'force-stop', package)
        adb('shell', 'am', 'start', '-W', '-n', package + '/.MainActivity')

    def node(label):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            adb('shell', 'uiautomator', 'dump', '/sdcard/axiotask-qualification.xml')
            document = adb('shell', 'cat', '/sdcard/axiotask-qualification.xml')
            matches = [item for item in ET.fromstring(document).iter('node')
                       if label in {item.get('text'), item.get('content-desc')}]
            if len(matches) == 1:
                return matches[0]
            require(len(matches) < 2, f'Ambiguous accessibility label: {label}')
            time.sleep(0.25)
        raise ValueError(f'Expected accessible label not found: {label}')

    def capture(name):
        data = adb('exec-out', 'screencap', '-p', binary=True)
        require(data.startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid screenshot')
        path = name + '.png'
        (root / path).write_bytes(data)
        evidence['screenshots'].append({'stage': name, 'path': path,
                                        'sha256': hashlib.sha256(data).hexdigest()})

    try:
        adb('install', str(apk))
        evidence['checks']['install'] = True
        launch()
        require(adb('shell', 'pidof', package).strip(), 'App did not stay running')
        evidence['checks']['launch'] = True
        capture('launch')
        for name in FLOWS:
            for step in scenario[name]:
                action = step['action']
                if action in {'tap', 'expect'}:
                    target = node(step['label'])
                    if action == 'tap':
                        bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', target.get('bounds', ''))
                        require(bounds, 'Missing target bounds')
                        left, top, right, bottom = map(int, bounds.groups())
                        adb('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))
                elif action == 'text':
                    adb('shell', 'input', 'text', step['value'].replace(' ', '%s'))
                elif action == 'back':
                    adb('shell', 'input', 'keyevent', '4')
                else:
                    launch()
            capture(name)
            evidence['checks'][name] = True
    finally:
        (root / 'smoke.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('Automated candidate flows passed. Inspect comparison screenshots before recording visual review.')


if __name__ == '__main__':
    main()
