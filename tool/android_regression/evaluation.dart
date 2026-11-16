import 'dart:convert';

import 'manifest.dart';
import 'protocol.dart';

enum CaseOutcome {
  passed,

  /// The test ran and an assertion or exception failed it.
  failed,

  /// The manifest expects the case in this subset but it never executed.
  missing,
  skipped,
  teardownFailed,

  /// The test reported a different pass label than the manifest records.
  labelMismatch,

  /// No executable contract exists yet; never counted as passing.
  outstanding,

  /// A case executed that the selected manifest subset does not contain.
  unexpected,
}

final class CaseResult {
  const CaseResult(this.id, this.outcome, {this.label, this.detail});

  final String id;
  final CaseOutcome outcome;
  final CaseLabel? label;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'outcome': outcome.name,
    'label': ?label?.wireName,
    'detail': ?detail,
  };
}

/// One test as reported by `flutter test --reporter json`.
final class ReportedTest {
  ReportedTest(this.name);

  final String name;
  String? result;
  bool skipped = false;
  bool hidden = false;
  final errors = <String>[];
  final events = <RegressionEvent>[];

  CaseEvent? get caseEvent => events.whereType<CaseEvent>().lastOrNull;

  TeardownEvent? get teardownEvent =>
      events.whereType<TeardownEvent>().lastOrNull;
}

/// Parsed machine output of one `flutter test --reporter json` process.
final class FlutterTestReport {
  FlutterTestReport._(this.tests, this.suiteSucceeded, this.protocolErrors);

  factory FlutterTestReport.parse(Iterable<String> lines) {
    final byId = <int, ReportedTest>{};
    bool? suiteSucceeded;
    final protocolErrors = <String>[];
    for (final line in lines) {
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue; // Build and tool output interleaved with reporter events.
      }
      if (decoded is! Map<String, Object?>) continue;
      switch (decoded['type']) {
        case 'testStart':
          final test = decoded['test']! as Map<String, Object?>;
          byId[test['id']! as int] = ReportedTest(test['name']! as String);
        case 'print':
          final test = byId[decoded['testID']];
          final message = decoded['message']! as String;
          try {
            final event = RegressionEvent.tryDecode(message);
            if (event != null) test?.events.add(event);
          } on FormatException catch (error) {
            protocolErrors.add('Malformed regression event: $error');
          }
        case 'error':
          byId[decoded['testID']]?.errors.add(decoded['error']! as String);
        case 'testDone':
          final test = byId[decoded['testID']];
          if (test != null) {
            test
              ..result = decoded['result']! as String
              ..skipped = decoded['skipped'] == true
              ..hidden = decoded['hidden'] == true;
          }
        case 'done':
          suiteSucceeded = decoded['success'] == true;
      }
    }
    return FlutterTestReport._(
      byId.values.where((test) => !test.hidden).toList(),
      suiteSucceeded,
      protocolErrors,
    );
  }

  final List<ReportedTest> tests;

  /// Null when the reporter never announced completion.
  final bool? suiteSucceeded;
  final List<String> protocolErrors;

  Iterable<RegressionEvent> get events => tests.expand((test) => test.events);
}

final class Evaluation {
  const Evaluation(this.results, this.infrastructureErrors);

  final List<CaseResult> results;
  final List<String> infrastructureErrors;

  bool get passed =>
      infrastructureErrors.isEmpty &&
      results.every((result) => result.outcome == CaseOutcome.passed);
}

/// Compares one run with the manifest subset it was expected to execute.
Evaluation evaluate({
  required List<ManifestEntry> expected,
  required FlutterTestReport report,
  required int processExitCode,
}) {
  final infrastructure = <String>[...report.protocolErrors];
  final testsByName = <String, ReportedTest>{};
  for (final test in report.tests) {
    if (_suiteHooks.contains(test.name)) {
      // The reporter only shows suite hooks when they fail; they are not cases.
      final error = test.errors.firstOrNull ?? 'result ${test.result}';
      infrastructure.add('Suite hook ${test.name} failed: $error');
      continue;
    }
    if (testsByName.containsKey(test.name)) {
      infrastructure.add('Case ${test.name} executed more than once');
    }
    testsByName[test.name] = test;
  }

  final results = <CaseResult>[
    for (final entry in expected)
      entry.contract == ContractState.outstanding
          ? CaseResult(
              entry.id,
              CaseOutcome.outstanding,
              detail: 'Owned by ${entry.owner}; planned in ${entry.testPath}',
            )
          : _judge(entry, testsByName.remove(entry.id)),
    for (final test in testsByName.values)
      CaseResult(
        test.name,
        CaseOutcome.unexpected,
        detail: 'Executed but absent from the selected manifest subset',
      ),
  ];

  if (report.tests.every((test) => _suiteHooks.contains(test.name))) {
    infrastructure.add('No test executed');
  }
  if (report.suiteSucceeded == null) {
    infrastructure.add('Test reporter did not report completion');
  }
  final anyCaseFailed = results.any(
    (result) =>
        result.outcome != CaseOutcome.passed &&
        result.outcome != CaseOutcome.outstanding,
  );
  if (processExitCode != 0 && !anyCaseFailed) {
    infrastructure.add(
      'flutter test exited with $processExitCode without a failing case',
    );
  }
  return Evaluation(results, infrastructure);
}

/// Synthetic entries package:test reports for failing suite-level hooks.
const _suiteHooks = <String>{'(setUpAll)', '(tearDownAll)'};

CaseResult _judge(ManifestEntry entry, ReportedTest? test) {
  if (test == null) {
    return CaseResult(
      entry.id,
      CaseOutcome.missing,
      detail: 'Expected in ${entry.testPath} but did not execute',
    );
  }
  if (test.skipped) {
    return CaseResult(entry.id, CaseOutcome.skipped);
  }
  final caseEvent = test.caseEvent;
  final teardown = test.teardownEvent;
  if (test.result != 'success' || caseEvent == null || !caseEvent.passed) {
    final detail = caseEvent?.error ?? test.errors.firstOrNull;
    if (caseEvent != null && caseEvent.passed && teardown?.clean == false) {
      return _teardownFailure(entry, teardown!);
    }
    return CaseResult(
      entry.id,
      CaseOutcome.failed,
      detail: detail ?? 'Test result ${test.result ?? 'unknown'}',
    );
  }
  if (teardown == null) {
    return CaseResult(
      entry.id,
      CaseOutcome.teardownFailed,
      detail: 'No teardown report',
    );
  }
  if (!teardown.clean) return _teardownFailure(entry, teardown);
  if (caseEvent.label != entry.label) {
    return CaseResult(
      entry.id,
      CaseOutcome.labelMismatch,
      label: caseEvent.label,
      detail: 'Manifest label is ${entry.label?.wireName}',
    );
  }
  return CaseResult(entry.id, CaseOutcome.passed, label: caseEvent.label);
}

CaseResult _teardownFailure(ManifestEntry entry, TeardownEvent teardown) =>
    CaseResult(
      entry.id,
      CaseOutcome.teardownFailed,
      detail: teardown.errors.join('; '),
    );
