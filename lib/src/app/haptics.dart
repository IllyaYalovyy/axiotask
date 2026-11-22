import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../features/tasks/tasks_view_model.dart';

/// The closed haptic vocabulary: the one seam through which the application
/// ever vibrates the device.
///
///   tick    — a task completed or reopened, a selection change, a due date
///             applied, a swipe crossing its action threshold;
///   confirm — a delete (single or bulk).
///
/// Nothing fires on scroll, navigation, synchronization or typing. The
/// "Haptics" setting silences every tone at once: with it off the scope
/// resolves to [NoHaptics], so no call site needs to know about the setting.
abstract interface class Haptics {
  void tick();

  void confirm();
}

final class NoHaptics implements Haptics {
  const NoHaptics();

  @override
  void tick() {}

  @override
  void confirm() {}
}

/// Flutter's haptic channel. Fire-and-forget: a gesture never waits on a
/// vibration, and a device without a haptic engine must not turn a tap into
/// an unhandled error.
final class PlatformHaptics implements Haptics {
  const PlatformHaptics();

  @override
  void tick() => _fire(HapticFeedback.selectionClick);

  @override
  void confirm() => _fire(HapticFeedback.mediumImpact);

  static void _fire(Future<void> Function() impact) =>
      unawaited(impact().catchError((Object _) {}));
}

/// Haptics exist only where there is a haptic engine to drive.
bool supportsHaptics(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;

/// Provides the effective [Haptics] to the widgets below it.
final class HapticsScope extends InheritedWidget {
  const HapticsScope({required this.haptics, required super.child, super.key});

  final Haptics haptics;

  /// The haptics in effect; silent when no scope is installed.
  static Haptics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HapticsScope>()?.haptics ??
      const NoHaptics();

  @override
  bool updateShouldNotify(HapticsScope oldWidget) =>
      !identical(haptics, oldWidget.haptics);
}

/// Answers committed local task commands with the matching tone.
///
/// It observes results rather than taps: an Undo record only exists once a
/// local command was durably stored, so a refused or failed action stays
/// silent and synchronization can never vibrate the device.
final class TaskHaptics extends StatefulWidget {
  const TaskHaptics({required this.viewModel, required this.child, super.key});

  final TasksViewModel viewModel;
  final Widget child;

  @override
  State<TaskHaptics> createState() => _TaskHapticsState();
}

final class _TaskHapticsState extends State<TaskHaptics> {
  late TasksViewState _previous = widget.viewModel.state;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_stateChanged);
  }

  @override
  void didUpdateWidget(covariant TaskHaptics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewModel, widget.viewModel)) {
      oldWidget.viewModel.removeListener(_stateChanged);
      _previous = widget.viewModel.state;
      widget.viewModel.addListener(_stateChanged);
    }
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_stateChanged);
    super.dispose();
  }

  void _stateChanged() {
    final previous = _previous;
    final next = widget.viewModel.state;
    _previous = next;
    if (!mounted) return;
    final haptics = HapticsScope.of(context);
    final deletes =
        next.taskDeleteUndos.length + next.taskDeleteGroupUndos.length;
    final previousDeletes =
        previous.taskDeleteUndos.length + previous.taskDeleteGroupUndos.length;
    if (deletes > previousDeletes) {
      haptics.confirm();
      return;
    }
    final completed =
        next.taskCompletionUndo != null &&
        !identical(next.taskCompletionUndo, previous.taskCompletionUndo);
    final rescheduled =
        next.taskDueChangeUndos.length > previous.taskDueChangeUndos.length;
    final selectionChanged =
        next.bulkSelectedTaskIds.length != previous.bulkSelectedTaskIds.length;
    if (completed || rescheduled || selectionChanged) haptics.tick();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
