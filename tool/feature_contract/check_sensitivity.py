#!/usr/bin/env python3
"""Prove the must-have feature contract fails when a feature is taken away.

A contract that cannot fail protects nothing. This copies the current source
to a disposable directory, removes or breaks one shipped capability at a time
exactly the way a careless rewrite would, and requires the named contract to
fail by assertion (a compile error does not count). It never changes this
checkout.

    python3 tool/feature_contract/check_sensitivity.py

Logs and results.json are kept in test-results/feature-contract-sensitivity.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
PRODUCT = 'lib/src/app/axiotask_product.dart'
CONTRACT = 'test/contract/must_have_features_test.dart'
SURFACE = 'test/contract/ui_surface_test.dart'

# (name, file, original, replacement, test file, test name pattern)
MUTATIONS = [
    ('support-unwired', PRODUCT,
     'supportProject: _supportProject,', 'supportProject: null,',
     CONTRACT, 'MH-SUPPORT-001'),
    ('account-session-unwired', PRODUCT,
     'session: runtime.accountSession,', 'session: null,',
     CONTRACT, 'MH-ACCOUNT-001'),
    ('about-version-lost', 'lib/src/features/about/about_view.dart',
     "subtitle: Text('v$version'),", "subtitle: const Text('version'),",
     CONTRACT, 'MH-ABOUT-001'),
    ('read-only-ignored', 'lib/src/sync/engine.dart',
     'var stopOperations = !publishLocalChanges;', 'var stopOperations = false;',
     CONTRACT, 'MH-SYNC-001'),
    ('auto-sync-setting-ignored', 'lib/src/app/tasks_feature_runtime.dart',
     '(await openedDevicePreferences.watch().first).autoSyncOnStartup,', 'true,',
     CONTRACT, 'MH-SYNC-002'),
    ('haptics-setting-ignored', 'lib/src/app/axiotask_app.dart',
     'preferences.haptics &&\n', 'true &&\n',
     CONTRACT, 'MH-PREF-002'),
    ('collapse-setting-ignored', 'lib/src/features/tasks/widgets/task_details.dart',
     'final showCompleted = _showCompletedOverride ?? !collapse;',
     'final showCompleted = _showCompletedOverride ?? false;',
     CONTRACT, 'MH-PREF-001'),
    ('share-removed', 'lib/src/features/tasks/widgets/export_sheet.dart',
     'if (viewModel.viewExportShare != null)', 'if (viewModel.viewExportShare == null)',
     CONTRACT, 'MH-EXPORT-002'),
    ('export-bypasses-sheet', 'lib/src/app/adaptive_shell.dart',
     'showViewExportSheet(context, viewModel: viewModel, phone: phone),',
     'viewModel.copyCurrentView(ViewExportFormat.markdown),',
     CONTRACT, 'MH-EXPORT-001'),
    ('menu-entry-removed', 'lib/src/app/adaptive_shell.dart',
     "            item('Sync activity', () => _open(context, builder)),\n",
     "            item('Sync', () => _open(context, builder)),\n",
     SURFACE, 'android'),
]

ASSERTION_MARKERS = (
    'Expected:', 'Too many elements', 'No element',
    'could not find any matching widgets', 'disappeared',
)


def run(command, directory, log):
    with log.open('w') as output:
        return subprocess.run(command, cwd=directory, stdout=output,
                              stderr=subprocess.STDOUT, timeout=900).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', default='test-results/feature-contract-sensitivity')
    args = parser.parse_args()
    artifacts = pathlib.Path(args.artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix='axiotask-contract-sensitivity-') as temporary:
        snapshot = pathlib.Path(temporary)
        # Current source, including uncommitted and new files, without
        # mutating this checkout or sharing Flutter's generated build files.
        names = subprocess.check_output(
            ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
            cwd=ROOT).decode().split('\0')
        for name in filter(None, names):
            source = ROOT / name
            if source.is_file():
                target = snapshot / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        if run(['flutter', 'pub', 'get', '--offline'], snapshot, artifacts / 'dependencies.log'):
            parser.exit(1, 'Disposable checkout dependency setup failed\n')
        baselines = {}
        for name, file, original, replacement, test, pattern in MUTATIONS:
            command = ['flutter', 'test', '--no-pub', test, '--plain-name', pattern,
                       '--reporter', 'expanded']
            key = (test, pattern)
            if key not in baselines:
                baselines[key] = run(command, snapshot, artifacts / f'{name}-baseline.log')
            baseline = baselines[key]
            path = snapshot / file
            source = path.read_text()
            if source.count(original) != 1:
                parser.exit(1, f'{name}: mutation anchor is not unique in {file}\n')
            if file.endswith('adaptive_shell.dart') and 'ViewExportFormat' in replacement:
                replacement_source = source.replace(original, replacement).replace(
                    "import '../domain/model/bulk_operations.dart';",
                    "import '../domain/export/view_export.dart';\n"
                    "import '../domain/model/bulk_operations.dart';")
            else:
                replacement_source = source.replace(original, replacement)
            try:
                path.write_text(replacement_source)
                failure = run(command, snapshot, artifacts / f'{name}-mutated.log')
            finally:
                path.write_text(source)
            output = (artifacts / f'{name}-mutated.log').read_text()
            # A compiler/setup error is not proof that the contract detects it.
            detected = baseline == 0 and failure != 0 and '[E]' in output and \
                'Compilation failed' not in output and \
                any(marker in output for marker in ASSERTION_MARKERS)
            results.append({'mutation': name, 'contract': pattern,
                            'baseline_exit': baseline, 'mutated_exit': failure,
                            'detected': detected})
            print(json.dumps(results[-1]), flush=True)
    (artifacts / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return 0 if all(result['detected'] for result in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
