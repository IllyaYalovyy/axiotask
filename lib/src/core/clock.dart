import 'dart:async';

abstract interface class Clock {
  DateTime now();

  Duration get monotonicElapsed;
}

abstract interface class ScheduledTimer {
  bool get isActive;

  bool cancel();
}

abstract interface class MonotonicScheduler {
  ScheduledTimer schedule(Duration delay, void Function() callback);
}

final class SystemClock implements Clock, MonotonicScheduler {
  SystemClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration get monotonicElapsed => _stopwatch.elapsed;

  @override
  DateTime now() => DateTime.now();

  @override
  ScheduledTimer schedule(Duration delay, void Function() callback) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    return _SystemScheduledTimer(Timer(delay, callback));
  }
}

final class ManualClock implements Clock, MonotonicScheduler {
  ManualClock(this._wallTime);

  DateTime _wallTime;
  Duration _monotonicElapsed = Duration.zero;
  final List<_ManualScheduledTimer> _timers = <_ManualScheduledTimer>[];
  var _nextTimerSequence = 0;

  @override
  Duration get monotonicElapsed => _monotonicElapsed;

  @override
  DateTime now() => _wallTime;

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    final target = _monotonicElapsed + duration;
    while (true) {
      final next = _nextDueAtOrBefore(target);
      if (next == null) break;
      final step = next.deadline - _monotonicElapsed;
      _monotonicElapsed = next.deadline;
      _wallTime = _wallTime.add(step);
      next
        ..active = false
        ..callback();
    }
    final remainder = target - _monotonicElapsed;
    _monotonicElapsed = target;
    _wallTime = _wallTime.add(remainder);
    _timers.removeWhere((timer) => !timer.active);
  }

  @override
  ScheduledTimer schedule(Duration delay, void Function() callback) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    final timer = _ManualScheduledTimer(
      deadline: _monotonicElapsed + delay,
      sequence: _nextTimerSequence++,
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  _ManualScheduledTimer? _nextDueAtOrBefore(Duration target) {
    _ManualScheduledTimer? selected;
    for (final timer in _timers) {
      if (!timer.active || timer.deadline > target) continue;
      if (selected == null ||
          timer.deadline < selected.deadline ||
          (timer.deadline == selected.deadline &&
              timer.sequence < selected.sequence)) {
        selected = timer;
      }
    }
    return selected;
  }
}

final class _SystemScheduledTimer implements ScheduledTimer {
  _SystemScheduledTimer(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  bool cancel() {
    if (!_timer.isActive) return false;
    _timer.cancel();
    return true;
  }
}

final class _ManualScheduledTimer implements ScheduledTimer {
  _ManualScheduledTimer({
    required this.deadline,
    required this.sequence,
    required this.callback,
  });

  final Duration deadline;
  final int sequence;
  final void Function() callback;
  bool active = true;

  @override
  bool get isActive => active;

  @override
  bool cancel() {
    if (!active) return false;
    active = false;
    return true;
  }
}
