import 'dart:convert';

import 'protocol.dart';

const supportedManifestSchema = 1;

enum ExpectedOutcome { pass, fail }

/// Whether an executable behavioral contract exists for the entry.
enum ContractState { implemented, outstanding }

enum EntryKind { auditCase, trackedFinding }

final class ManifestEntry {
  const ManifestEntry({
    required this.id,
    required this.kind,
    required this.expected,
    required this.label,
    required this.contract,
    required this.testPath,
    required this.owner,
    required this.subsets,
  });

  final String id;
  final EntryKind kind;
  final ExpectedOutcome expected;

  /// Pass label for entries expected to pass; null for expected failures.
  final CaseLabel? label;
  final ContractState contract;
  final String testPath;
  final String owner;
  final Set<String> subsets;
}

final class RegressionManifest {
  RegressionManifest._({
    required this.manifestVersion,
    required this.subsets,
    required this.correctiveTasks,
    required this.entries,
  });

  factory RegressionManifest.parse(String source) {
    final json = _object(jsonDecode(source), 'manifest');
    final schema = json['schema_version'];
    if (schema != supportedManifestSchema) {
      throw FormatException('Unsupported manifest schema: $schema');
    }
    final subsets = _object(json['subsets'], 'subsets').keys.toSet();
    final correctiveTasks = _object(
      json['corrective_tasks'],
      'corrective_tasks',
    ).keys.toSet();
    final entries = <ManifestEntry>[
      for (final value in _list(json['cases'], 'cases'))
        _entry(value, EntryKind.auditCase),
      for (final value in _list(json['tracked_findings'], 'tracked_findings'))
        _entry(value, EntryKind.trackedFinding),
    ];
    final ids = <String>{};
    for (final entry in entries) {
      if (!ids.add(entry.id)) {
        throw FormatException('Duplicate manifest entry: ${entry.id}');
      }
      if (!correctiveTasks.contains(entry.owner)) {
        throw FormatException('${entry.id} has unknown owner ${entry.owner}');
      }
      final unknown = entry.subsets.difference(subsets);
      if (unknown.isNotEmpty) {
        throw FormatException('${entry.id} names unknown subsets $unknown');
      }
      if ((entry.expected == ExpectedOutcome.pass) != (entry.label != null)) {
        throw FormatException(
          '${entry.id} must carry a label exactly when expected to pass',
        );
      }
      if (entry.expected == ExpectedOutcome.fail &&
          entry.contract == ContractState.implemented) {
        throw FormatException(
          '${entry.id} is an expected failure but claims an implemented '
          'passing contract',
        );
      }
    }
    return RegressionManifest._(
      manifestVersion: json['manifest_version']! as int,
      subsets: subsets,
      correctiveTasks: correctiveTasks,
      entries: List<ManifestEntry>.unmodifiable(entries),
    );
  }

  final int manifestVersion;
  final Set<String> subsets;
  final Set<String> correctiveTasks;
  final List<ManifestEntry> entries;

  List<ManifestEntry> subset(String name) {
    if (!subsets.contains(name)) {
      throw ArgumentError.value(name, 'subset', 'is not defined');
    }
    return entries.where((entry) => entry.subsets.contains(name)).toList();
  }

  static ManifestEntry _entry(Object? value, EntryKind kind) {
    final json = _object(value, 'entry');
    final baseline = _object(json['baseline'], 'baseline');
    final label = baseline['label'] as String?;
    return ManifestEntry(
      id: json['id']! as String,
      kind: kind,
      expected: ExpectedOutcome.values.byName(baseline['expected']! as String),
      label: label == null ? null : CaseLabel.parse(label),
      contract: ContractState.values.byName(json['contract']! as String),
      testPath: json['test_path']! as String,
      owner: json['owner']! as String,
      subsets: Set<String>.from(_list(json['subsets'], 'subsets')),
    );
  }

  static Map<String, Object?> _object(Object? value, String name) {
    if (value is! Map<String, Object?>) {
      throw FormatException('Manifest $name must be an object');
    }
    return value;
  }

  static List<Object?> _list(Object? value, String name) {
    if (value is! List<Object?>) {
      throw FormatException('Manifest $name must be a list');
    }
    return value;
  }
}
