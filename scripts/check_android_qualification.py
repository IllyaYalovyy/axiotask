#!/usr/bin/env python3
"""Reject publication without matching native acceptance and physical APK smoke evidence."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess

CERTIFICATE = '1935e06653e69ddaf6e616a6f2c35b53425f14a3e94cd8daaf219338757cb796'
SMOKE_CHECKS = {'install', 'launch', 'menu', 'capture_edit_persistence',
                'completion_undo', 'navigation', 'comparison_screenshots_reviewed'}
SMOKE_SCREENSHOTS = {'launch', 'menu', 'capture_edit_persistence', 'completion_undo', 'navigation'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(acceptance, smoke, manifest, commit, digest, evidence_root, acceptance_root=None):
    require(re.fullmatch(r'[0-9a-f]{40}', commit), 'Invalid source commit')
    require(acceptance['commit'] == {'head': commit, 'tracked_changes': False},
            'Acceptance must describe the exact clean source commit')
    require(acceptance['subset'] == 'complete' and acceptance['platform'] == 'android',
            'Complete native Android acceptance is required')
    require(acceptance['execution_mode'] == 'instrumented-debug' and
            acceptance['isolated_package'] == 'com.axiotask.app.integrationtest',
            'Isolated instrumented-debug acceptance is required')
    require(acceptance['passed'] is True and acceptance['flutter_test_exit_code'] == 0,
            'Android acceptance failed')
    require(acceptance['production_package_unchanged'] is True and
            acceptance['infrastructure_errors'] == [] and acceptance['teardown_errors'] == [],
            'Acceptance isolation or infrastructure checks failed')
    require(acceptance['manifest_version'] == manifest['manifest_version'], 'Stale manifest')
    entries = manifest['cases'] + manifest['tracked_findings']
    require(all(e['contract'] == 'implemented' and e['baseline']['expected'] == 'pass'
                for e in entries), 'Outstanding acceptance contracts')
    expected = {e['id']: e['baseline']['label'] for e in entries}
    cases = acceptance['cases']
    require(len(cases) == len(expected) and {e['id'] for e in cases} == set(expected),
            'Missing, unexpected or duplicate acceptance cases')
    require(all(e['outcome'] == 'passed' and e['label'] == expected[e['id']] for e in cases),
            'Failed or mislabeled acceptance case')
    require(acceptance['device']['model'] and
            int(acceptance['device']['android_api']) > 0 and acceptance['device']['abi'],
            'Missing native device/API evidence')
    require({e['id'] for e in acceptance['environments']} == set(expected) and
            all(e['platform'] == 'android' and e['logical_size'] and
                e['device_pixel_ratio'] > 0 for e in acceptance['environments']),
            'Missing per-case native viewport evidence')
    require({e['case'] for e in acceptance['screenshots']} == set(expected),
            'Missing per-case screenshots')
    root = (acceptance_root or evidence_root).resolve()
    for screenshot in acceptance['screenshots']:
        validate_screenshot(root, screenshot['file'], screenshot['sha256'])
    require(smoke['schema_version'] == 1 and smoke['source_commit'] == commit and
            smoke['apk_sha256'] == digest, 'Stale or mismatched release APK evidence')
    require(smoke['application_id'] == 'com.axiotask.app' and
            smoke['signing_certificate_sha256'] == CERTIFICATE and smoke['debuggable'] is False,
            'Release identity mismatch')
    require(smoke['execution_mode'] == 'signed-release-physical' and
            smoke['device']['kind'] == 'physical' and smoke['device']['serial'] and
            smoke['device']['model'] and type(smoke['device']['api']) is int and
            smoke['device']['api'] > 0, 'Physical signed-candidate qualification is required')
    require(set(smoke['checks']) == SMOKE_CHECKS and
            all(v is True for v in smoke['checks'].values()), 'Incomplete release smoke checks')
    require(smoke['reviewed_by'].strip() and smoke['screenshots'], 'Missing visual review')
    require({e['stage'] for e in smoke['screenshots']} == SMOKE_SCREENSHOTS and
            len(smoke['screenshots']) == len(SMOKE_SCREENSHOTS) and
            len({e['path'] for e in smoke['screenshots']}) == len(SMOKE_SCREENSHOTS),
            'Missing, duplicate or unexpected workflow screenshots')
    root = evidence_root.resolve()
    for screenshot in smoke['screenshots']:
        validate_screenshot(root, screenshot['path'], screenshot['sha256'])


def validate_screenshot(root, name, digest):
    path = (root / name).resolve()
    require(path.is_relative_to(root) and path.is_file(), 'Invalid screenshot path')
    require(hashlib.sha256(path.read_bytes()).hexdigest() == digest,
            'Screenshot digest mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('acceptance', 'smoke', 'apk', 'commit', 'apksigner', 'apkanalyzer'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--manifest', default='integration_test/android_regression/manifest.json')
    args = parser.parse_args()
    load = lambda path: json.loads(pathlib.Path(path).read_text())
    try:
        digest = hashlib.sha256(pathlib.Path(args.apk).read_bytes()).hexdigest()
        validate(load(args.acceptance), load(args.smoke), load(args.manifest), args.commit,
                 digest, pathlib.Path(args.smoke).parent, pathlib.Path(args.acceptance).parent)
        report = subprocess.check_output([args.apksigner, 'verify', '--print-certs', args.apk], text=True)
        signers = set(re.findall(r'certificate SHA-256 digest: ([0-9a-fA-F]{64})', report))
        require({s.lower() for s in signers} == {CERTIFICATE}, 'Actual APK signer mismatch')
        for field, expected in [('application-id', 'com.axiotask.app'), ('debuggable', 'false')]:
            actual = subprocess.check_output([args.apkanalyzer, 'manifest', field, args.apk], text=True).strip()
            require(actual == expected, 'Actual APK ' + field + ' mismatch')
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Android qualification rejected: {error}\n')
    print('Matching native acceptance and physical signed-release qualification verified')


if __name__ == '__main__':
    main()
