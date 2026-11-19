import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/android_regression/protocol.dart';
import '../../tool/android_regression/runner.dart';

void main() {
  late Directory root;
  late RunnerOptions options;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('axiotask-runner-test-');
    final manifest = File('${root.path}/manifest.json')
      ..writeAsStringSync(jsonEncode(_syntheticManifest));
    options = RunnerOptions(
      subset: 'baseline',
      device: 'emulator-5554',
      artifacts: Directory('${root.path}/artifacts'),
      manifestPath: manifest.path,
    );
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'process output retains evidence but progress omits screenshot payloads',
    () async {
      final executable = File('${root.path}/flutter');
      await executable.writeAsString(r'''#!/bin/sh
cat <<'DATA'
Starting device
"plain JSON string"
{"type":"testStart","test":{"name":"probe"}}
{"type":"print","message":"AXIOTASK_REGRESSION screenshot payload"}
DATA
printf 'startup diagnostic\n' >&2
exit 7
''');
      expect((await Process.run('chmod', ['+x', executable.path])).exitCode, 0);
      final progress = <String>[];
      final result = await runZoned(
        () => runProcess(executable.path, ['test']),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => progress.add(line),
        ),
      );
      expect(result.exitCode, 7);
      expect(result.stdout, contains('AXIOTASK_REGRESSION screenshot payload'));
      expect(result.stderr, 'startup diagnostic\n');
      expect(
        progress,
        containsAll(['Starting device', 'RUN probe', 'startup diagnostic']),
      );
      expect(progress, isNot(anyElement(contains('screenshot payload'))));
    },
  );

  Future<(int, List<String>, _FakeDevice)> runWith(
    _FakeDevice device, {
    RunnerOptions? override,
  }) async {
    final lines = <String>[];
    final code = await runRegression(
      override ?? options,
      device.run,
      log: lines.add,
    );
    return (code, lines, device);
  }

  test('passes when every expected case passes and tears down', () async {
    final (code, lines, device) = await runWith(
      _FakeDevice(cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')]),
    );

    expect(code, 0);
    expect(lines, contains('CASE 01_one PASSED [working]'));
    expect(lines, contains('CASE 02_two PASSED [limited-pass]'));
    expect(device.uninstalled, isTrue);
    final run = _runJson(options);
    expect(run['passed'], isTrue);
    expect(run['execution_mode'], 'instrumented-debug');
    expect(run['isolated_package'], isolatedPackage);
    expect(run['commit'], {'head': 'abc123', 'tracked_changes': false});
    expect(run['device'], containsPair('android_api', '36'));
    expect(run['screenshots'], [
      {
        'case': '01_one',
        'file': 'screenshots/01_one_end.png',
        'sha256':
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      },
    ]);
    expect(
      File('${options.artifacts.path}/screenshots/01_one_end.png')
          .readAsBytesSync(),
      utf8.encode('abc'),
    );
  });

  test('fails on an assertion failure', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.fail('01_one'), _Case.pass('02_two')],
        flutterExitCode: 1,
      ),
    );

    expect(code, 1);
    expect(lines, contains('CASE 01_one FAILED - Expected: true'));
  });

  test(
    'removes a stranded test installation before starting a new run',
    () async {
      final device = _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        previouslyInstalled: true,
      );
      final (code, _, _) = await runWith(device);
      expect(code, 0);
      expect(device.removedBeforeRun, isTrue);
    },
  );

  test(
    'refuses to run when a stranded test installation cannot be removed',
    () async {
      final device = _FakeDevice(
        cases: const <_Case>[],
        previouslyInstalled: true,
        uninstallSucceeds: false,
      );
      final (code, lines, _) = await runWith(device);
      expect(code, 1);
      expect(device.ranTests, isFalse);
      expect(
        lines,
        anyElement(startsWith('INFRASTRUCTURE Could not uninstall')),
      );
    },
  );

  test('fails when an expected case never executes', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(cases: <_Case>[_Case.pass('01_one')]),
    );

    expect(code, 1);
    expect(lines, anyElement(startsWith('CASE 02_two MISSING')));
  });

  test('a combined entrypoint still requires every manifest case', () async {
    final combined = RunnerOptions(
      subset: options.subset,
      device: options.device,
      artifacts: options.artifacts,
      manifestPath: options.manifestPath,
      testEntrypoint: 'integration_test/android_regression/complete_test.dart',
    );
    final device = _FakeDevice(cases: <_Case>[_Case.pass('01_one')]);
    final calls = <List<String>>[];
    final code = await runRegression(combined, (executable, arguments) {
      if (executable == 'flutter') calls.add(arguments);
      return device.run(executable, arguments);
    }, log: (_) {});
    expect(code, 1);
    expect(
      calls.singleWhere((args) => args.first == 'test'),
      contains(combined.testEntrypoint),
    );
    expect(
      _runJson(combined)['cases'],
      anyElement(containsPair('outcome', 'missing')),
    );
  });

  test('fails on a teardown error even when assertions pass', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[
          _Case.pass('01_one'),
          _Case.pass('02_two', teardownErrors: <String>['orientation: boom']),
        ],
      ),
    );

    expect(code, 1);
    expect(lines, contains('CASE 02_two TEARDOWNFAILED - orientation: boom'));
  });

  test('fails when a case omits its teardown report', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[
          _Case.pass('01_one'),
          _Case.pass('02_two', tornDown: false),
        ],
      ),
    );

    expect(code, 1);
    expect(lines, contains('CASE 02_two TEARDOWNFAILED - No teardown report'));
  });

  test('fails when a skipped case is reported as done', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.skipped('02_two')],
      ),
    );

    expect(code, 1);
    expect(lines, contains('CASE 02_two SKIPPED'));
  });

  test('fails when a limited pass is reported as fully working', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[
          _Case.pass('01_one'),
          _Case.pass('02_two', label: CaseLabel.working),
        ],
      ),
    );

    expect(code, 1);
    expect(lines, anyElement(startsWith('CASE 02_two LABELMISMATCH')));
  });

  test('fails when an unlisted case executes', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[
          _Case.pass('01_one'),
          _Case.pass('02_two'),
          _Case.pass('99_extra'),
        ],
      ),
    );

    expect(code, 1);
    expect(lines, anyElement(startsWith('CASE 99_extra UNEXPECTED')));
  });

  test('fails on infrastructure failure without test output', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: const <_Case>[],
        flutterExitCode: 1,
        reportDone: false,
      ),
    );

    expect(code, 1);
    expect(lines, contains('INFRASTRUCTURE No test executed'));
    expect(
      lines,
      contains('INFRASTRUCTURE Test reporter did not report completion'),
    );
  });

  test('fails when flutter exits nonzero although cases passed', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        flutterExitCode: 1,
      ),
    );

    expect(code, 1);
    expect(
      lines,
      contains(
        'INFRASTRUCTURE flutter test exited with 1 without a failing case',
      ),
    );
  });

  test('reports a failing suite hook as infrastructure, not a case', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        flutterExitCode: 1,
        failingSuiteHook: true,
      ),
    );

    expect(code, 1);
    expect(
      lines,
      contains(
        'INFRASTRUCTURE Suite hook (tearDownAll) failed: '
        'Lost connection to device.',
      ),
    );
    expect(lines, isNot(anyElement(contains('UNEXPECTED'))));
  });

  test('does not mistake a lost device for a production change', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        deviceLostDuringRun: true,
      ),
    );

    expect(code, 1);
    expect(
      lines,
      contains('TEARDOWN Could not verify $productionPackage after the run'),
    );
    expect(lines, isNot(anyElement(contains('changed'))));
    expect(_runJson(options)['production_package_unchanged'], isNull);
  });

  test('refuses to install when production state is unreadable', () async {
    final (code, lines, device) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        productionStateUnreadable: true,
      ),
    );

    expect(code, 1);
    expect(device.built, isFalse);
    expect(device.ranTests, isFalse);
    expect(
      lines,
      contains(
        'INFRASTRUCTURE Could not read the state of $productionPackage; '
        'refusing to install',
      ),
    );
  });

  test('never installs a test APK carrying the production ID', () async {
    final (code, lines, device) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        builtApplicationId: productionPackage,
      ),
    );

    expect(code, 1);
    expect(device.ranTests, isFalse);
    expect(lines, contains('CASE 01_one MISSING - Not executed'));
    expect(lines, anyElement(contains('refusing to install')));
  });

  test('fails when the production installation changes', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        productionChangesDuringRun: true,
      ),
    );

    expect(code, 1);
    expect(
      lines,
      contains('TEARDOWN Production package $productionPackage changed'),
    );
    expect(_runJson(options)['production_package_unchanged'], isFalse);
  });

  test('fails when the isolated package cannot be removed', () async {
    final (code, lines, _) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        uninstallSucceeds: false,
      ),
    );

    expect(code, 1);
    expect(lines, anyElement(startsWith('TEARDOWN Could not uninstall')));
  });

  test(
    'reports outstanding contracts as failures of the complete gate',
    () async {
      final complete = RunnerOptions(
        subset: 'complete',
        device: options.device,
        artifacts: options.artifacts,
        manifestPath: options.manifestPath,
      );
      final (code, lines, _) = await runWith(
        _FakeDevice(cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')]),
        override: complete,
      );

      expect(code, 1);
      expect(
        lines,
        contains(
          'CASE 03_outstanding OUTSTANDING - Owned by later-fix; planned in '
          'integration_test/later_test.dart',
        ),
      );
    },
  );

  test('runs host devices without Android package handling', () async {
    final (code, _, device) = await runWith(
      _FakeDevice(
        cases: <_Case>[_Case.pass('01_one'), _Case.pass('02_two')],
        android: false,
      ),
      override: RunnerOptions(
        subset: 'baseline',
        device: 'linux',
        artifacts: options.artifacts,
        manifestPath: options.manifestPath,
      ),
    );

    expect(code, 0);
    expect(device.built, isFalse);
    expect(_runJson(options)['platform'], 'host');
  });

  test('rejects incomplete command lines', () {
    expect(
      () => RunnerOptions.parse(<String>['--subset', 'baseline']),
      throwsFormatException,
    );
  });
}

Map<String, Object?> _runJson(RunnerOptions options) =>
    jsonDecode(File('${options.artifacts.path}/run.json').readAsStringSync())
        as Map<String, Object?>;

const _syntheticManifest = <String, Object?>{
  'schema_version': 1,
  'manifest_version': 7,
  'subsets': <String, String>{'baseline': 'b', 'complete': 'c'},
  'corrective_tasks': <String, String>{'baseline-owner': 'b', 'later-fix': 'l'},
  'cases': <Map<String, Object?>>[
    <String, Object?>{
      'id': '01_one',
      'baseline': <String, String>{'expected': 'pass', 'label': 'working'},
      'contract': 'implemented',
      'test_path': 'integration_test/baseline_test.dart',
      'owner': 'baseline-owner',
      'subsets': <String>['baseline', 'complete'],
    },
    <String, Object?>{
      'id': '02_two',
      'baseline': <String, String>{'expected': 'pass', 'label': 'limited-pass'},
      'contract': 'implemented',
      'test_path': 'integration_test/baseline_test.dart',
      'owner': 'baseline-owner',
      'subsets': <String>['baseline', 'complete'],
    },
    <String, Object?>{
      'id': '03_outstanding',
      'baseline': <String, String>{'expected': 'fail'},
      'contract': 'outstanding',
      'test_path': 'integration_test/later_test.dart',
      'owner': 'later-fix',
      'subsets': <String>['complete'],
    },
  ],
  'tracked_findings': <Object?>[],
};

final class _Case {
  _Case.pass(
    this.id, {
    this.label,
    this.teardownErrors = const <String>[],
    this.tornDown = true,
  }) : passed = true,
       skipped = false;

  _Case.fail(this.id)
    : passed = false,
      skipped = false,
      label = null,
      teardownErrors = const <String>[],
      tornDown = true;

  _Case.skipped(this.id)
    : passed = true,
      skipped = true,
      label = null,
      teardownErrors = const <String>[],
      tornDown = false;

  final String id;
  final bool passed;
  final bool skipped;
  final CaseLabel? label;
  final List<String> teardownErrors;
  final bool tornDown;
}

/// Simulates git, adb, apkanalyzer and `flutter test --reporter json`.
final class _FakeDevice {
  _FakeDevice({
    required this.cases,
    this.flutterExitCode = 0,
    this.reportDone = true,
    this.android = true,
    this.builtApplicationId = isolatedPackage,
    this.productionChangesDuringRun = false,
    this.uninstallSucceeds = true,
    this.failingSuiteHook = false,
    this.deviceLostDuringRun = false,
    this.productionStateUnreadable = false,
    this.previouslyInstalled = false,
  });

  final List<_Case> cases;
  final int flutterExitCode;
  final bool reportDone;
  final bool android;
  final String builtApplicationId;
  final bool productionChangesDuringRun;
  final bool uninstallSucceeds;
  final bool failingSuiteHook;
  final bool deviceLostDuringRun;
  final bool productionStateUnreadable;
  bool previouslyInstalled;
  bool removedBeforeRun = false;

  bool built = false;
  bool ranTests = false;
  bool uninstalled = false;

  Future<CommandResult> run(String executable, List<String> arguments) async {
    final command = arguments.join(' ');
    return switch (executable) {
      'git' when command == 'rev-parse HEAD' => const CommandResult(
        0,
        'abc123\n',
      ),
      'git' => const CommandResult(0, ''),
      'adb' => _adb(command),
      'apkanalyzer' => CommandResult(0, '$builtApplicationId\n'),
      'flutter' when arguments.first == 'build' => _build(),
      'flutter' when arguments.first == 'test' => _test(arguments),
      _ => throw StateError('Unexpected command $executable $command'),
    };
  }

  CommandResult _build() {
    built = true;
    return const CommandResult(0, 'Built app-debug.apk');
  }

  CommandResult _adb(String command) {
    if (!android) return const CommandResult(1, '', 'device not found');
    if (command.endsWith('get-state')) return const CommandResult(0, 'device');
    if (command.contains('getprop ro.build.version.sdk')) {
      return const CommandResult(0, '36\n');
    }
    if (command.contains('getprop')) return const CommandResult(0, 'value\n');
    if (productionStateUnreadable || (deviceLostDuringRun && ranTests)) {
      if (command.contains('dumpsys') || command.contains('pm list')) {
        return const CommandResult(1, '', 'error: closed');
      }
    }
    if (command.contains('dumpsys package')) {
      final updated = productionChangesDuringRun && ranTests ? '2' : '1';
      return CommandResult(
        0,
        '    versionName=1.5.6\n    lastUpdateTime=2026-11-1$updated\n',
      );
    }
    if (command.contains('pm list packages')) {
      return CommandResult(
        0,
        ranTests || previouslyInstalled ? 'package:$isolatedPackage\n' : '',
      );
    }
    if (command.contains('uninstall $isolatedPackage')) {
      uninstalled = uninstallSucceeds;
      if (uninstallSucceeds && !ranTests) {
        removedBeforeRun = true;
        previouslyInstalled = false;
      }
      return CommandResult(
        uninstallSucceeds ? 0 : 1,
        uninstallSucceeds ? 'Success\n' : 'Failure [DELETE_FAILED]\n',
      );
    }
    throw StateError('Unexpected adb $command');
  }

  CommandResult _test(List<String> arguments) {
    ranTests = true;
    if (android) {
      expect(arguments, contains('--no-uninstall'));
    }
    final lines = <String>[
      'Running Gradle task assembleDebug...',
      _event({'type': 'testStart', 'test': _testInfo(0, 'loading')}),
      _event({
        'type': 'testDone',
        'testID': 0,
        'result': 'success',
        'hidden': true,
      }),
    ];
    for (final (index, value) in cases.indexed) {
      final id = index + 1;
      lines.add(_event({'type': 'testStart', 'test': _testInfo(id, value.id)}));
      void emit(RegressionEvent event) => lines.add(
        _event({'type': 'print', 'testID': id, 'message': event.encode()}),
      );
      if (index == 0 && value.passed) {
        for (final chunk in ScreenshotChunkEvent.split(
          value.id,
          '${value.id}_end',
          utf8.encode('abc'),
        )) {
          emit(chunk);
        }
      }
      if (!value.skipped) {
        emit(
          CaseEvent(
            value.id,
            label:
                value.label ??
                (value.id == '02_two'
                    ? CaseLabel.limitedPass
                    : CaseLabel.working),
            passed: value.passed,
            error: value.passed ? null : 'Expected: true',
          ),
        );
      }
      if (value.tornDown) {
        emit(TeardownEvent(value.id, errors: value.teardownErrors));
      }
      final success = value.passed && value.teardownErrors.isEmpty;
      lines.add(
        _event({
          'type': 'testDone',
          'testID': id,
          'result': success ? 'success' : 'failure',
          'skipped': value.skipped,
          'hidden': false,
        }),
      );
    }
    if (failingSuiteHook) {
      final id = cases.length + 1;
      lines
        ..add(
          _event({'type': 'testStart', 'test': _testInfo(id, '(tearDownAll)')}),
        )
        ..add(
          _event({
            'type': 'error',
            'testID': id,
            'error': 'Lost connection to device.',
            'isFailure': false,
          }),
        )
        ..add(
          _event({
            'type': 'testDone',
            'testID': id,
            'result': 'error',
            'skipped': false,
            'hidden': false,
          }),
        );
    }
    if (reportDone) {
      lines.add(_event({'type': 'done', 'success': flutterExitCode == 0}));
    }
    return CommandResult(flutterExitCode, lines.join('\n'));
  }

  static Map<String, Object?> _testInfo(int id, String name) => {
    'id': id,
    'name': name,
  };

  static String _event(Map<String, Object?> event) => jsonEncode(event);
}
