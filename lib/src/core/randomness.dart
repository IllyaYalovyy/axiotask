import 'dart:math';

abstract interface class RandomSource {
  List<int> nextBytes(int length);

  /// Selects a full-jitter delay in the inclusive range zero through [maximum].
  Duration fullJitter(Duration maximum);
}

final class SecureRandomSource implements RandomSource {
  SecureRandomSource() : _random = Random.secure();

  final Random _random;

  @override
  List<int> nextBytes(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must not be negative');
    }
    return List<int>.generate(length, (_) => _random.nextInt(256));
  }

  @override
  Duration fullJitter(Duration maximum) {
    if (maximum.isNegative) {
      throw ArgumentError.value(maximum, 'maximum', 'must not be negative');
    }
    if (maximum == Duration.zero) return Duration.zero;
    return Duration(microseconds: _random.nextInt(maximum.inMicroseconds + 1));
  }
}

final class SequenceRandomSource implements RandomSource {
  SequenceRandomSource(Iterable<int> bytes)
    : _bytes = List<int>.unmodifiable(bytes) {
    if (_bytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError.value(bytes, 'bytes', 'must contain byte values');
    }
  }

  final List<int> _bytes;
  int _offset = 0;

  @override
  List<int> nextBytes(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must not be negative');
    }
    if (_offset + length > _bytes.length) {
      throw StateError('The deterministic random sequence is exhausted.');
    }
    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  @override
  Duration fullJitter(Duration maximum) {
    if (maximum.isNegative) {
      throw ArgumentError.value(maximum, 'maximum', 'must not be negative');
    }
    if (maximum == Duration.zero) return Duration.zero;
    final bytes = nextBytes(8);
    var value = 0;
    for (final byte in bytes) {
      value = ((value << 8) | byte) & 0x7fffffffffffffff;
    }
    return Duration(microseconds: value % (maximum.inMicroseconds + 1));
  }
}
