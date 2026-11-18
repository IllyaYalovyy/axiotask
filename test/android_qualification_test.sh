#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import copy, hashlib, importlib.util, pathlib, tempfile, unittest, sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('guard', 'scripts/check_android_qualification.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
sys.path.insert(0, str(pathlib.Path('scripts').resolve()))
import smoke_android_candidate as collector

class QualificationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        (self.root / 'screen.png').write_bytes(b'synthetic screenshot')
        self.commit = 'a' * 40
        self.digest = 'b' * 64
        self.manifest = {'manifest_version': 1, 'cases': [
            {'id': 'case', 'contract': 'implemented', 'baseline': {'expected': 'pass', 'label': 'working'}}
        ], 'tracked_findings': []}
        self.acceptance = {'commit': {'head': self.commit, 'tracked_changes': False},
            'subset': 'complete', 'platform': 'android', 'passed': True, 'flutter_test_exit_code': 0,
            'production_package_unchanged': True, 'infrastructure_errors': [], 'teardown_errors': [],
            'manifest_version': 1, 'cases': [{'id': 'case', 'outcome': 'passed', 'label': 'working'}],
            'device': {'android_api': '36', 'model': 'fixture', 'abi': 'x86_64'},
            'environments': [{'id': 'case', 'platform': 'android',
                              'logical_size': 'Size(360, 800)', 'device_pixel_ratio': 1}],
            'screenshots': [{'case': 'case', 'file': 'screen.png',
                             'sha256': hashlib.sha256(b'synthetic screenshot').hexdigest()}]}
        self.smoke = {'schema_version': 1, 'source_commit': self.commit, 'apk_sha256': self.digest,
            'application_id': 'com.axiotask.app', 'signing_certificate_sha256': guard.CERTIFICATE,
            'debuggable': False, 'execution_mode': 'signed-release-physical',
            'device': {'kind': 'physical', 'serial': 'synthetic', 'model': 'fixture', 'api': 36},
            'checks': dict.fromkeys(guard.SMOKE_CHECKS, True), 'reviewed_by': 'fixture reviewer',
            'screenshots': [{'stage': stage, 'path': stage + '.png',
                             'sha256': hashlib.sha256(b'synthetic screenshot').hexdigest()}
                            for stage in sorted(guard.SMOKE_SCREENSHOTS)]}
        for screenshot in self.smoke['screenshots']:
            (self.root / screenshot['path']).write_bytes(b'synthetic screenshot')

    def check(self):
        guard.validate(self.acceptance, self.smoke, self.manifest, self.commit, self.digest, self.root)

    def test_matching_fixture(self):
        self.check()

    def test_reject_bad_acceptance(self):
        good = copy.deepcopy(self.acceptance)
        for key, value in [('commit', {'head': 'c' * 40, 'tracked_changes': False}),
                           ('commit', {'head': self.commit, 'tracked_changes': True}),
                           ('subset', 'baseline'), ('platform', 'host'), ('passed', False),
                           ('flutter_test_exit_code', 1), ('production_package_unchanged', False),
                           ('infrastructure_errors', ['offline']), ('teardown_errors', ['leak']),
                           ('manifest_version', 0), ('cases', []),
                           ('cases', good['cases'] * 2), ('screenshots', [])]:
            with self.subTest(key=key, value=value):
                self.acceptance = copy.deepcopy(good)
                self.acceptance[key] = value
                with self.assertRaises(ValueError): self.check()

    def test_reject_bad_smoke(self):
        good = copy.deepcopy(self.smoke)
        for key, value in [('source_commit', 'c' * 40), ('apk_sha256', 'd' * 64),
                           ('application_id', 'com.axiotask.app.integrationtest'),
                           ('signing_certificate_sha256', 'e' * 64), ('debuggable', True),
                           ('execution_mode', 'instrumented-debug'), ('checks', {}),
                           ('reviewed_by', ''), ('screenshots', [])]:
            with self.subTest(key=key):
                self.smoke = copy.deepcopy(good)
                self.smoke[key] = value
                with self.assertRaises(ValueError): self.check()

    def test_reject_skipped_and_failed_cases(self):
        for outcome in ['skipped', 'missing', 'failed', 'outstanding', 'teardownFailed']:
            self.acceptance['cases'][0]['outcome'] = outcome
            with self.assertRaises(ValueError): self.check()

    def test_reject_outstanding_contract(self):
        self.manifest['cases'][0]['contract'] = 'outstanding'
        with self.assertRaises(ValueError): self.check()

    def test_reject_emulator_as_physical(self):
        self.smoke['device']['kind'] = 'emulator'
        with self.assertRaises(ValueError): self.check()

    def test_reject_missing_and_tampered_screenshots(self):
        (self.root / 'screen.png').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.check()
        (self.root / 'screen.png').write_bytes(b'synthetic screenshot')
        self.smoke['screenshots'][0]['path'] = '../missing.png'
        with self.assertRaises(ValueError): self.check()

    def test_reject_missing_workflow_screenshot(self):
        self.smoke['screenshots'].pop()
        with self.assertRaises(ValueError): self.check()

    def test_reject_incomplete_native_metadata(self):
        self.acceptance['environments'] = []
        with self.assertRaises(ValueError): self.check()

    def test_collector_scenario_requires_durable_outcomes(self):
        scenario = {name: [{'action': 'expect', 'label': 'Synthetic outcome'}]
                    for name in collector.FLOWS}
        with self.assertRaises(ValueError): collector.validate_scenario(scenario)
        scenario['capture_edit_persistence'].insert(0, {'action': 'relaunch'})
        collector.validate_scenario(scenario)
        scenario['navigation'] = [{'action': 'tap', 'label': 'All'}]
        with self.assertRaises(ValueError): collector.validate_scenario(scenario)

    def test_collector_rejects_shell_input_and_unknown_actions(self):
        scenario = {name: [{'action': 'expect', 'label': 'Synthetic outcome'}]
                    for name in collector.FLOWS}
        scenario['capture_edit_persistence'].insert(0, {'action': 'relaunch'})
        for step in [{'action': 'text', 'value': 'x; rm'}, {'action': 'shell'}]:
            scenario['navigation'].append(step)
            with self.assertRaises(ValueError): collector.validate_scenario(scenario)
            scenario['navigation'].pop()

unittest.main()
PY
