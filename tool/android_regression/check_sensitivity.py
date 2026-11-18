#!/usr/bin/env python3
"""Verify representative regressions are detected in a disposable source copy."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHELL = 'lib/src/app/adaptive_shell.dart'
WIDGET_TEST = 'test/features/tasks/adaptive_shell_test.dart'
MUTATIONS = [
    ('menu', SHELL, 'constraints: _taskActionMenuConstraints,\n                    onSelected: widget.onAction,',
     'constraints: const BoxConstraints.tightFor(width: 48),\n                    onSelected: widget.onAction,',
     WIDGET_TEST, '01 overflow menu is readable and reachable'),
    ('gesture', SHELL, 'onComplete: widget.onSwipeComplete,', 'onComplete: null,',
     WIDGET_TEST, '02 a right swipe completes exactly the swiped row'),
    ('wrong-id', SHELL,
     'viewModel.setTaskCompletion(\n                                          task.id,',
     'viewModel.setTaskCompletion(\n                                          const TaskId(11),',
     WIDGET_TEST, '02 a right swipe completes exactly the swiped row'),
    ('cascade', 'lib/src/domain/policy/completion_policy.dart',
     'final frontier = <TaskId>[task.id];', 'final frontier = <TaskId>[];',
     'test/data/database/completion_repository_test.dart',
     'parent completion is atomic, offline, and survives reopening'),
]


def run(command, directory, log):
    with log.open('w') as output:
        return subprocess.run(command, cwd=directory, stdout=output,
                              stderr=subprocess.STDOUT, timeout=600).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', default='test-results/android-sensitivity')
    args = parser.parse_args()
    artifacts = pathlib.Path(args.artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix='axiotask-sensitivity-') as temporary:
        snapshot = pathlib.Path(temporary)
        # Copy current tracked source, including uncommitted fixes, without
        # mutating this checkout or sharing Flutter's generated build files.
        names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
        for name in filter(None, names):
            source = ROOT / name
            if source.is_file():
                target = snapshot / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        if run(['flutter', 'pub', 'get', '--offline'], snapshot, artifacts / 'dependencies.log'):
            parser.exit(1, 'Disposable checkout dependency setup failed\n')
        for name, file, original, replacement, test, pattern in MUTATIONS:
            command = ['flutter', 'test', '--no-pub', test, '--name', pattern, '--reporter', 'expanded']
            baseline = run(command, snapshot, artifacts / f'{name}-baseline.log')
            path = snapshot / file
            source = path.read_text()
            if source.count(original) != 1:
                parser.exit(1, f'{name}: mutation anchor is not unique\n')
            try:
                path.write_text(source.replace(original, replacement))
                failure = run(command, snapshot, artifacts / f'{name}-mutated.log')
            finally:
                path.write_text(source)
            output = (artifacts / f'{name}-mutated.log').read_text()
            # A compiler/setup error is not proof that the assertion detects it.
            detected = baseline == 0 and failure != 0 and '[E]' in output and \
                ('Expected:' in output or 'Too many elements' in output or 'No element' in output)
            results.append({'mutation': name, 'baseline_exit': baseline,
                            'mutated_exit': failure, 'detected': detected})
            print(json.dumps(results[-1]), flush=True)
    (artifacts / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return 0 if all(result['detected'] for result in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
