import 'dart:async';

import 'package:axiotask/src/core/clock.dart';

/// A test clock with independently controlled UTC wall and monotonic time.
///
/// Timers use only [monotonicElapsed]. Wall-time jumps therefore cannot fire,
/// postpone, or reorder a deadline.
final class FakeClock implements Clock {
  FakeClock(DateTime wallTime) : _wallTime = _requireUtc(wallTime);

  DateTime _wallTime;
  Duration _monotonicElapsed = Duration.zero;
  final List<_ScheduledFakeTimer> _timers = <_ScheduledFakeTimer>[];
  var _nextSequence = 0;

  @override
  Duration get monotonicElapsed => _monotonicElapsed;

  @override
  DateTime now() => _wallTime;

  int get pendingTimerCount => _timers.where((timer) => timer.isActive).length;

  FakeTimerHandle schedule(Duration delay, void Function() callback) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    final timer = _ScheduledFakeTimer(
      deadline: _monotonicElapsed + delay,
      sequence: _nextSequence++,
      callback: callback,
    );
    _timers.add(timer);
    return FakeTimerHandle._(timer);
  }

  Future<void> delay(Duration duration) {
    final completer = Completer<void>();
    schedule(duration, completer.complete);
    return completer.future;
  }

  void advance(Duration duration) => _advance(duration, advanceWall: true);

  void advanceMonotonic(Duration duration) =>
      _advance(duration, advanceWall: false);

  void jumpWall(Duration offset) {
    _wallTime = _wallTime.add(offset);
  }

  void setWallTime(DateTime value) {
    _wallTime = _requireUtc(value);
  }

  void _advance(Duration duration, {required bool advanceWall}) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    final target = _monotonicElapsed + duration;
    while (true) {
      final next = _nextDueAtOrBefore(target);
      if (next == null) break;
      final step = next.deadline - _monotonicElapsed;
      _monotonicElapsed = next.deadline;
      if (advanceWall) _wallTime = _wallTime.add(step);
      next
        ..isActive = false
        ..callback();
    }
    final remainder = target - _monotonicElapsed;
    _monotonicElapsed = target;
    if (advanceWall) _wallTime = _wallTime.add(remainder);
    _timers.removeWhere((timer) => !timer.isActive);
  }

  _ScheduledFakeTimer? _nextDueAtOrBefore(Duration target) {
    _ScheduledFakeTimer? selected;
    for (final timer in _timers) {
      if (!timer.isActive || timer.deadline > target) continue;
      if (selected == null ||
          timer.deadline < selected.deadline ||
          (timer.deadline == selected.deadline &&
              timer.sequence < selected.sequence)) {
        selected = timer;
      }
    }
    return selected;
  }

  static DateTime _requireUtc(DateTime value) {
    if (!value.isUtc) {
      throw ArgumentError.value(value, 'wallTime', 'must be UTC');
    }
    return value;
  }
}

final class FakeTimerHandle {
  FakeTimerHandle._(this._timer);

  final _ScheduledFakeTimer _timer;

  bool get isActive => _timer.isActive;

  bool cancel() {
    if (!_timer.isActive) return false;
    _timer.isActive = false;
    return true;
  }
}

final class _ScheduledFakeTimer {
  _ScheduledFakeTimer({
    required this.deadline,
    required this.sequence,
    required this.callback,
  });

  final Duration deadline;
  final int sequence;
  final void Function() callback;
  bool isActive = true;
}
