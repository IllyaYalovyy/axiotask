import 'dart:collection';

import 'package:axiotask/src/core/randomness.dart';

/// Non-cryptographic deterministic randomness for synchronization tests only.
final class FakeRandom implements RandomSource {
  FakeRandom.seeded(int seed)
    : _state = seed & _stateMask,
      _scripted = false,
      _scriptedJitter = Queue<Duration>();

  FakeRandom.scriptedJitter(Iterable<Duration> jitter)
    : _state = 1,
      _scripted = true,
      _scriptedJitter = Queue<Duration>.from(jitter) {
    if (_scriptedJitter.any((value) => value.isNegative)) {
      throw ArgumentError.value(jitter, 'jitter', 'must not be negative');
    }
  }

  static const int _stateMask = 0x7fffffff;

  int _state;
  final bool _scripted;
  final Queue<Duration> _scriptedJitter;

  @override
  List<int> nextBytes(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must not be negative');
    }
    return List<int>.generate(length, (_) => _nextRaw() & 0xff);
  }

  /// Returns a full-jitter delay in the inclusive range zero through [maximum].
  Duration fullJitter(Duration maximum) {
    if (maximum.isNegative) {
      throw ArgumentError.value(maximum, 'maximum', 'must not be negative');
    }
    if (maximum == Duration.zero) return Duration.zero;
    if (_scriptedJitter.isNotEmpty) {
      final selected = _scriptedJitter.removeFirst();
      if (selected > maximum) {
        throw ArgumentError.value(
          selected,
          'scriptedJitter',
          'must not exceed the requested maximum',
        );
      }
      return selected;
    }
    if (_scripted) {
      throw StateError('The deterministic jitter sequence is exhausted.');
    }
    final inclusiveMicroseconds = maximum.inMicroseconds + 1;
    return Duration(microseconds: _nextRaw() % inclusiveMicroseconds);
  }

  int _nextRaw() {
    _state = (1103515245 * _state + 12345) & _stateMask;
    return _state;
  }
}
