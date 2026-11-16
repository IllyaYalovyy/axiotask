/// Line protocol shared by the native regression harness and its host runner.
///
/// The harness prints one event per line as `prefix + JSON`. The runner reads
/// those lines from the `flutter test --reporter json` print events, so the
/// protocol must stay free of Flutter imports.
library;

import 'dart:convert';

const regressionEventPrefix = 'AXIOTASK_REGRESSION ';

/// Maximum base64 characters carried by one screenshot event line.
const screenshotChunkLength = 32 * 1024;

enum CaseLabel {
  working('working'),
  limitedPass('limited-pass');

  const CaseLabel(this.wireName);

  final String wireName;

  static CaseLabel parse(String value) => CaseLabel.values.firstWhere(
    (label) => label.wireName == value,
    orElse: () => throw FormatException('Unknown case label: $value'),
  );
}

sealed class RegressionEvent {
  const RegressionEvent(this.caseId);

  final String caseId;

  Map<String, Object?> toJson();

  String encode() => '$regressionEventPrefix${jsonEncode(toJson())}';

  /// Returns the event carried by [line], or null for unrelated output.
  static RegressionEvent? tryDecode(String line) {
    final start = line.indexOf(regressionEventPrefix);
    if (start < 0) return null;
    final Object? decoded = jsonDecode(
      line.substring(start + regressionEventPrefix.length),
    );
    if (decoded is! Map<String, Object?>) {
      throw FormatException('Regression event is not an object: $line');
    }
    final caseId = _string(decoded, 'id');
    return switch (_string(decoded, 'event')) {
      'environment' => EnvironmentEvent(
        caseId,
        platform: _string(decoded, 'platform'),
        logicalSize: _string(decoded, 'logical_size'),
        devicePixelRatio: (decoded['device_pixel_ratio']! as num).toDouble(),
      ),
      'case' => CaseEvent(
        caseId,
        label: CaseLabel.parse(_string(decoded, 'label')),
        passed: _string(decoded, 'outcome') == 'passed',
        error: decoded['error'] as String?,
      ),
      'teardown' => TeardownEvent(
        caseId,
        errors: List<String>.from(decoded['errors']! as List<Object?>),
      ),
      'screenshot' => ScreenshotChunkEvent(
        caseId,
        name: _string(decoded, 'name'),
        chunk: decoded['chunk']! as int,
        chunks: decoded['chunks']! as int,
        data: _string(decoded, 'data'),
      ),
      final other => throw FormatException('Unknown regression event: $other'),
    };
  }

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Regression event field "$key" must be a string');
    }
    return value;
  }
}

final class EnvironmentEvent extends RegressionEvent {
  const EnvironmentEvent(
    super.caseId, {
    required this.platform,
    required this.logicalSize,
    required this.devicePixelRatio,
  });

  final String platform;
  final String logicalSize;
  final double devicePixelRatio;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'event': 'environment',
    'id': caseId,
    'platform': platform,
    'logical_size': logicalSize,
    'device_pixel_ratio': devicePixelRatio,
  };
}

final class CaseEvent extends RegressionEvent {
  const CaseEvent(
    super.caseId, {
    required this.label,
    required this.passed,
    this.error,
  });

  final CaseLabel label;
  final bool passed;
  final String? error;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'event': 'case',
    'id': caseId,
    'label': label.wireName,
    'outcome': passed ? 'passed' : 'failed',
    'error': ?error,
  };
}

final class TeardownEvent extends RegressionEvent {
  const TeardownEvent(super.caseId, {required this.errors});

  final List<String> errors;

  bool get clean => errors.isEmpty;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'event': 'teardown',
    'id': caseId,
    'errors': errors,
  };
}

final class ScreenshotChunkEvent extends RegressionEvent {
  const ScreenshotChunkEvent(
    super.caseId, {
    required this.name,
    required this.chunk,
    required this.chunks,
    required this.data,
  });

  final String name;
  final int chunk;
  final int chunks;
  final String data;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'event': 'screenshot',
    'id': caseId,
    'name': name,
    'chunk': chunk,
    'chunks': chunks,
    'data': data,
  };

  /// Splits PNG [bytes] into protocol events small enough for one line each.
  static List<ScreenshotChunkEvent> split(
    String caseId,
    String name,
    List<int> bytes,
  ) {
    final encoded = base64Encode(bytes);
    final chunks = (encoded.length / screenshotChunkLength).ceil();
    return <ScreenshotChunkEvent>[
      for (var index = 0; index < chunks; index += 1)
        ScreenshotChunkEvent(
          caseId,
          name: name,
          chunk: index,
          chunks: chunks,
          data: encoded.substring(
            index * screenshotChunkLength,
            ((index + 1) * screenshotChunkLength).clamp(0, encoded.length),
          ),
        ),
    ];
  }
}
