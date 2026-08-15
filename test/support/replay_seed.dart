import 'dart:async';
import 'dart:io';

final class ReplaySeed {
  const ReplaySeed(this.value) : assert(value >= 0), assert(value <= maxValue);

  static const String environmentKey = 'AXIOTASK_REPLAY_SEED';
  static const int maxValue = 0x7fffffff;

  final int value;

  static ReplaySeed resolve({
    required int fallback,
    Map<String, String>? environment,
  }) {
    final raw = (environment ?? Platform.environment)[environmentKey];
    if (raw == null) return ReplaySeed(_requireRange(fallback, 'fallback'));
    final normalized = raw.trim().toLowerCase();
    final parsed = normalized.startsWith('0x')
        ? int.tryParse(normalized.substring(2), radix: 16)
        : int.tryParse(normalized);
    if (parsed == null) {
      throw FormatException('$environmentKey must be an integer seed.');
    }
    return ReplaySeed(_requireRange(parsed, environmentKey));
  }

  String get replayHint => 'Replay with $environmentKey=$value';

  ReplayRandom random() => ReplayRandom(value);

  @override
  bool operator ==(Object other) => other is ReplaySeed && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ReplaySeed($value)';

  static int _requireRange(int value, String name) {
    if (value < 0 || value > maxValue) {
      throw RangeError.range(value, 0, maxValue, name);
    }
    return value;
  }
}

/// A deliberately specified generator so a seed has stable repository meaning.
final class ReplayRandom {
  ReplayRandom(int seed) : _state = seed & ReplaySeed.maxValue;

  var _state = 0;

  int nextInt(int maximumExclusive) {
    if (maximumExclusive <= 0) {
      throw ArgumentError.value(
        maximumExclusive,
        'maximumExclusive',
        'must be positive',
      );
    }
    _state = (1103515245 * _state + 12345) & ReplaySeed.maxValue;
    return _state % maximumExclusive;
  }

  bool nextBool() => nextInt(2) == 1;
}

List<Command> generateCommands<Command>({
  required ReplaySeed seed,
  required int count,
  required Command Function(ReplayRandom random, int index) generate,
}) {
  if (count < 0) {
    throw ArgumentError.value(count, 'count', 'must not be negative');
  }
  final random = seed.random();
  return List<Command>.unmodifiable(
    List<Command>.generate(count, (index) => generate(random, index)),
  );
}

/// Deterministically reduces a failing command trace to a one-minimal trace.
Future<List<Command>> shrinkFailingTrace<Command>(
  List<Command> original, {
  required FutureOr<bool> Function(List<Command> candidate) fails,
}) async {
  var current = List<Command>.of(original);
  if (!await fails(List<Command>.unmodifiable(current))) {
    throw ArgumentError.value(original, 'original', 'must reproduce failure');
  }
  var changed = true;
  while (changed && current.isNotEmpty) {
    changed = false;
    for (var index = 0; index < current.length; index += 1) {
      final candidate = List<Command>.of(current)..removeAt(index);
      if (await fails(List<Command>.unmodifiable(candidate))) {
        current = candidate;
        changed = true;
        break;
      }
    }
  }
  return List<Command>.unmodifiable(current);
}
