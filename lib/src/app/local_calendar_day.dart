// One app-wide local calendar-day signal. Date-derived providers and mounted
// UI watch this rather than each owning a timer, so an overnight-open app and
// a resumed mobile app agree on when "today" changed.

import 'package:async/async.dart';
import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

DateTime _localDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// The current local day, updated at the next local midnight and on resume.
class LocalCalendarDay extends Notifier<DateTime> {
  @override
  DateTime build() => _localDay(clock.now());

  /// Re-read the local clock.
  void refresh() {
    final next = _localDay(clock.now());
    if (next != state) state = next;
  }
}

/// The lifecycle owner's one cancellable wait for the following local midnight.
class LocalCalendarDayScheduler {
  LocalCalendarDayScheduler(this._onDayChange);

  final VoidCallback _onDayChange;
  RestartableTimer? _timer;

  void schedule() {
    _timer?.cancel();
    final now = clock.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _timer = RestartableTimer(next.difference(now), () {
      _onDayChange();
      schedule();
    });
  }

  void dispose() => _timer?.cancel();
}

final localCalendarDayProvider = NotifierProvider<LocalCalendarDay, DateTime>(
  LocalCalendarDay.new,
);

/// Rechecks the shared day when Flutter resumes after a suspended timer.
class LocalCalendarDayLifecycleObserver extends ConsumerStatefulWidget {
  const LocalCalendarDayLifecycleObserver({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LocalCalendarDayLifecycleObserver> createState() =>
      _LocalCalendarDayLifecycleObserverState();
}

class _LocalCalendarDayLifecycleObserverState
    extends ConsumerState<LocalCalendarDayLifecycleObserver> {
  late final AppLifecycleListener _listener;
  late final LocalCalendarDay _day;
  late final LocalCalendarDayScheduler _scheduler;

  @override
  void initState() {
    super.initState();
    _day = ref.read(localCalendarDayProvider.notifier);
    _scheduler = LocalCalendarDayScheduler(_day.refresh)..schedule();
    _listener = AppLifecycleListener(onStateChange: _onStateChange);
  }

  void _onStateChange(AppLifecycleState state) {
    if (mounted && state == AppLifecycleState.resumed) {
      _day.refresh();
      _scheduler.schedule();
    }
  }

  @override
  void dispose() {
    _listener.dispose();
    _scheduler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
