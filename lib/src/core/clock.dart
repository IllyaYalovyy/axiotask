abstract interface class Clock {
  DateTime now();

  Duration get monotonicElapsed;
}

final class SystemClock implements Clock {
  SystemClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration get monotonicElapsed => _stopwatch.elapsed;

  @override
  DateTime now() => DateTime.now();
}

final class ManualClock implements Clock {
  ManualClock(this._wallTime);

  DateTime _wallTime;
  Duration _monotonicElapsed = Duration.zero;

  @override
  Duration get monotonicElapsed => _monotonicElapsed;

  @override
  DateTime now() => _wallTime;

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    _wallTime = _wallTime.add(duration);
    _monotonicElapsed += duration;
  }
}
