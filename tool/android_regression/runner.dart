import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'evaluation.dart';
import 'manifest.dart';
import 'protocol.dart';

const productionPackage = 'com.axiotask.app';

/// Matches `applicationIdSuffix` for builds of non-`lib/` Dart targets in
/// android/app/build.gradle.kts.
const isolatedPackage = '$productionPackage.integrationtest';

final class CommandResult {
  const CommandResult(this.exitCode, this.stdout, [this.stderr = '']);

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef CommandRunner = Future<CommandResult> Function(
  String executable,
  List<String> arguments,
);

final class RunnerOptions {
  const RunnerOptions({
    required this.subset,
    required this.device,
    required this.artifacts,
    this.manifestPath = 'integration_test/android_regression/manifest.json',
    this.flutter = 'flutter',
    this.adb = 'adb',
    this.apkanalyzer = 'apkanalyzer',
    this.git = 'git',
    this.testEntrypoint,
  });

  final String subset;
  final String device;
  final Directory artifacts;
  final String manifestPath;
  final String flutter;
  final String adb;
  final String apkanalyzer;
  final String git;
  final String? testEntrypoint;

  static const usage =
      'Usage: dart run tool/android_regression/run.dart '
      '--subset <baseline|complete> --device <device-id> '
      '--artifacts <directory> [--manifest <path>] [--flutter <path>] '
      '[--adb <path>] [--apkanalyzer <path>] [--test-entrypoint <path>]';

  static RunnerOptions parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      final key = arguments[index];
      if (!key.startsWith('--') || index + 1 >= arguments.length) {
        throw FormatException('Unexpected argument "$key"\n$usage');
      }
      values[key.substring(2)] = arguments[index + 1];
    }
    String required(String key) =>
        values.remove(key) ?? (throw FormatException('Missing --$key\n$usage'));
    final options = RunnerOptions(
      subset: required('subset'),
      device: required('device'),
      artifacts: Directory(required('artifacts')),
      manifestPath:
          values.remove('manifest') ??
          'integration_test/android_regression/manifest.json',
      flutter: values.remove('flutter') ?? 'flutter',
      adb: values.remove('adb') ?? 'adb',
      apkanalyzer: values.remove('apkanalyzer') ?? 'apkanalyzer',
      testEntrypoint: values.remove('test-entrypoint'),
    );
    if (values.isNotEmpty) {
      throw FormatException('Unknown options ${values.keys}\n$usage');
    }
    return options;
  }
}

/// Runs one manifest subset and returns the process exit code.
///
/// Exit code 0 requires every expected case to execute, pass with its
/// manifest label and tear down cleanly, with no infrastructure failure.
Future<int> runRegression(
  RunnerOptions options,
  CommandRunner run, {
  void Function(String line) log = print,
}) async {
  final manifest = RegressionManifest.parse(
    await File(options.manifestPath).readAsString(),
  );
  final expected = manifest.subset(options.subset);
  final testPaths = <String>{
    for (final entry in expected)
      if (entry.contract == ContractState.implemented) entry.testPath,
  }.toList()..sort();
  final executionPaths = options.testEntrypoint == null
      ? testPaths
      : <String>[options.testEntrypoint!];
  await options.artifacts.create(recursive: true);
  final infrastructure = <String>[];
  final teardown = <String>[];

  final commit = await _gitState(options, run);
  final android = await _isAndroid(options, run);
  Map<String, String>? device;
  String? productionBefore;
  if (android) {
    device = await _deviceProperties(options, run);
    productionBefore = await _packageFingerprint(options, run);
  }

  var testExitCode = -1;
  var reporterLines = const <String>[];
  if (testPaths.isEmpty) {
    infrastructure.add('Subset ${options.subset} has no implemented test');
  } else if (android && productionBefore == null) {
    infrastructure.add(
      'Could not read the state of $productionPackage; refusing to install',
    );
  } else if (!android ||
      await _verifyIsolatedBuild(options, run, executionPaths)) {
    final result = await run(options.flutter, <String>[
      'test',
      ...executionPaths,
      '-d',
      options.device,
      '--reporter',
      'json',
      if (android) '--no-uninstall',
    ]);
    testExitCode = result.exitCode;
    reporterLines = const LineSplitter().convert(result.stdout);
    await _write(options, 'flutter-test.jsonl', result.stdout);
    await _write(options, 'flutter-test.stderr.log', result.stderr);
  } else {
    infrastructure.add(
      'Built test APK is not the isolated package $isolatedPackage; '
      'refusing to install it',
    );
  }

  bool? productionUnchanged;
  String? productionAfter;
  if (android) {
    teardown.addAll(await _removeIsolatedPackage(options, run));
    productionAfter = await _packageFingerprint(options, run);
    if (productionAfter == null) {
      teardown.add('Could not verify $productionPackage after the run');
    } else if (productionBefore != null) {
      productionUnchanged = productionAfter == productionBefore;
      if (!productionUnchanged) {
        teardown.add('Production package $productionPackage changed');
      }
    }
  }

  final report = FlutterTestReport.parse(reporterLines);
  final evaluation = testExitCode == -1
      ? Evaluation(<CaseResult>[
          for (final entry in expected)
            CaseResult(entry.id, CaseOutcome.missing, detail: 'Not executed'),
        ], infrastructure)
      : evaluate(
          expected: expected,
          report: report,
          processExitCode: testExitCode,
        );
  final infrastructureErrors = <String>[
    ...infrastructure,
    if (testExitCode != -1) ...evaluation.infrastructureErrors,
  ];
  final screenshots = await _writeScreenshots(
    options,
    report.events,
    infrastructureErrors,
  );

  for (final result in evaluation.results) {
    final label = result.label == null ? '' : ' [${result.label!.wireName}]';
    final detail = result.detail == null ? '' : ' - ${result.detail}';
    log('CASE ${result.id} ${result.outcome.name.toUpperCase()}$label$detail');
  }
  for (final error in infrastructureErrors) {
    log('INFRASTRUCTURE $error');
  }
  for (final error in teardown) {
    log('TEARDOWN $error');
  }
  final passed =
      evaluation.results.every((r) => r.outcome == CaseOutcome.passed) &&
      infrastructureErrors.isEmpty &&
      teardown.isEmpty;
  await _write(
    options,
    'run.json',
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'subset': options.subset,
      'manifest_version': manifest.manifestVersion,
      'commit': commit,
      'device_id': options.device,
      'platform': android ? 'android' : 'host',
      'device': device,
      'isolated_package': android ? isolatedPackage : null,
      'production_package_before': productionBefore,
      'production_package_after': productionAfter,
      'production_package_unchanged': productionUnchanged,
      'test_paths': testPaths,
      'execution_paths': executionPaths,
      'flutter_test_exit_code': testExitCode,
      'cases': [for (final result in evaluation.results) result.toJson()],
      'environments': [
        for (final event in report.events.whereType<EnvironmentEvent>())
          event.toJson(),
      ],
      'screenshots': screenshots,
      'infrastructure_errors': infrastructureErrors,
      'teardown_errors': teardown,
      'passed': passed,
    }),
  );
  log(
    passed
        ? 'Subset ${options.subset} passed'
        : 'Subset ${options.subset} FAILED',
  );
  return passed ? 0 : 1;
}

Future<Map<String, Object?>> _gitState(
  RunnerOptions options,
  CommandRunner run,
) async {
  final head = await run(options.git, <String>['rev-parse', 'HEAD']);
  final status = await run(options.git, <String>[
    'status',
    '--porcelain',
    '--untracked-files=no',
  ]);
  return <String, Object?>{
    'head': head.stdout.trim(),
    'tracked_changes': status.stdout.trim().isNotEmpty,
  };
}

Future<bool> _isAndroid(RunnerOptions options, CommandRunner run) async {
  try {
    final state = await run(options.adb, <String>[
      '-s',
      options.device,
      'get-state',
    ]);
    return state.exitCode == 0 && state.stdout.trim() == 'device';
  } on ProcessException {
    return false;
  }
}

Future<Map<String, String>> _deviceProperties(
  RunnerOptions options,
  CommandRunner run,
) async => <String, String>{
  for (final (key, property) in const <(String, String)>[
    ('model', 'ro.product.model'),
    ('android_release', 'ro.build.version.release'),
    ('android_api', 'ro.build.version.sdk'),
    ('abi', 'ro.product.cpu.abi'),
  ])
    key: (await run(options.adb, <String>[
      '-s',
      options.device,
      'shell',
      'getprop',
      property,
    ])).stdout.trim(),
};

/// Install identity of the production package, "absent" when it is not
/// installed, or null when the device could not be queried.
Future<String?> _packageFingerprint(
  RunnerOptions options,
  CommandRunner run,
) async {
  final dump = await run(options.adb, <String>[
    '-s',
    options.device,
    'shell',
    'dumpsys',
    'package',
    productionPackage,
  ]);
  if (dump.exitCode != 0) return null;
  final identity = const LineSplitter()
      .convert(dump.stdout)
      .map((line) => line.trim())
      .where(
        (line) =>
            line.startsWith('versionCode=') ||
            line.startsWith('versionName=') ||
            line.startsWith('firstInstallTime=') ||
            line.startsWith('lastUpdateTime='),
      )
      .toSet()
      .toList();
  return identity.isEmpty ? 'absent' : identity.join('\n');
}

/// Builds the first test target and confirms its application ID before any
/// install, because Flutter would otherwise replace a same-ID installation.
Future<bool> _verifyIsolatedBuild(
  RunnerOptions options,
  CommandRunner run,
  List<String> testPaths,
) async {
  final build = await run(options.flutter, <String>[
    'build',
    'apk',
    '--debug',
    '--target',
    testPaths.first,
  ]);
  await _write(
    options,
    'flutter-build-apk.log',
    '${build.stdout}\n${build.stderr}',
  );
  if (build.exitCode != 0) return false;
  final id = await run(options.apkanalyzer, <String>[
    'manifest',
    'application-id',
    'build/app/outputs/flutter-apk/app-debug.apk',
  ]);
  return id.exitCode == 0 && id.stdout.trim() == isolatedPackage;
}

Future<List<String>> _removeIsolatedPackage(
  RunnerOptions options,
  CommandRunner run,
) async {
  final listed = await run(options.adb, <String>[
    '-s',
    options.device,
    'shell',
    'pm',
    'list',
    'packages',
    isolatedPackage,
  ]);
  final installed = const LineSplitter()
      .convert(listed.stdout)
      .contains('package:$isolatedPackage');
  if (!installed) return const <String>[];
  final removed = await run(options.adb, <String>[
    '-s',
    options.device,
    'uninstall',
    isolatedPackage,
  ]);
  return removed.exitCode == 0 && removed.stdout.contains('Success')
      ? const <String>[]
      : <String>['Could not uninstall $isolatedPackage: ${removed.stdout}'];
}

Future<List<Map<String, Object?>>> _writeScreenshots(
  RunnerOptions options,
  Iterable<RegressionEvent> events,
  List<String> errors,
) async {
  final chunks = <String, List<ScreenshotChunkEvent>>{};
  for (final event in events.whereType<ScreenshotChunkEvent>()) {
    (chunks[event.name] ??= <ScreenshotChunkEvent>[]).add(event);
  }
  final directory = Directory('${options.artifacts.path}/screenshots');
  final written = <Map<String, Object?>>[];
  for (final MapEntry(key: name, value: parts) in chunks.entries) {
    parts.sort((left, right) => left.chunk.compareTo(right.chunk));
    if (parts.length != parts.first.chunks) {
      errors.add('Screenshot $name arrived incomplete');
      continue;
    }
    final bytes = base64Decode(parts.map((part) => part.data).join());
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(bytes);
    written.add(<String, Object?>{
      'case': parts.first.caseId,
      'file': 'screenshots/$name.png',
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  return written;
}

Future<void> _write(RunnerOptions options, String name, String contents) =>
    File('${options.artifacts.path}/$name').writeAsString(contents);

Future<CommandResult> runProcess(
  String executable,
  List<String> arguments,
) async {
  final result = await Process.run(executable, arguments);
  return CommandResult(
    result.exitCode,
    result.stdout as String,
    result.stderr as String,
  );
}
