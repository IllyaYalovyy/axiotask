import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/navigation_state.dart';
import '../../../domain/policy/date_workflow.dart';

/// Horizontal travel a touch swipe needs before releasing it acts.
const double taskSwipeActionDistance = 80;

/// How far the row content follows the finger, so the user sees the action
/// it will take without the row leaving the screen.
const double _maximumReveal = 96;

/// Touch-only swipe actions shared by task rows and subtask rows.
///
/// A swipe right of at least [taskSwipeActionDistance] calls [onComplete];
/// a swipe left of at least that distance calls [onSchedule]. Shorter,
/// mostly vertical or cancelled swipes only settle the row back. The
/// recognizer accepts touch pointers only, so mouse hover, right-click and
/// pointer drag-and-drop keep their meaning, and the gesture arena separates
/// the horizontal swipe from vertical scrolling, row taps and the long press
/// that starts selection.
/// A null callback disables that direction (for example a completed row has
/// nothing to complete; swiping right never reopens a task).
final class TaskSwipeActions extends StatefulWidget {
  const TaskSwipeActions({
    required this.child,
    this.onComplete,
    this.onSchedule,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final VoidCallback? onComplete;
  final VoidCallback? onSchedule;
  final bool enabled;

  @override
  State<TaskSwipeActions> createState() => _TaskSwipeActionsState();
}

final class _TaskSwipeActionsState extends State<TaskSwipeActions> {
  static const _touchOnly = <PointerDeviceKind>{PointerDeviceKind.touch};

  double _travel = 0;
  // Vertical drift of the swipe. Where no scrollable competes for vertical
  // drags (a short list), the horizontal recognizer would otherwise accept a
  // steep diagonal; only a mostly horizontal swipe acts.
  Offset? _origin;
  double _drift = 0;
  bool _armed = false;
  // The drag recognizer ends an accepted drag the same way whether the
  // finger lifted or the system cancelled the pointer (another app, a system
  // gesture, a dialog). A cancelled swipe must never act.
  bool _pointerCancelled = false;

  VoidCallback? get _complete => widget.enabled ? widget.onComplete : null;
  VoidCallback? get _schedule => widget.enabled ? widget.onSchedule : null;

  @override
  void didUpdateWidget(covariant TaskSwipeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A command started elsewhere disables the row mid-swipe; the swipe then
    // cannot act, so it must not keep promising that it will.
    // The framework rebuilds after this, so the fields are cleared directly.
    if (!widget.enabled) _clear();
  }

  /// The action a release at [travel] would take, if any.
  VoidCallback? _actionAt(double travel) {
    if (_pointerCancelled || _drift >= travel.abs()) return null;
    if (travel >= taskSwipeActionDistance) return _complete;
    if (travel <= -taskSwipeActionDistance) return _schedule;
    return null;
  }

  void _start(DragStartDetails details) {
    _clear();
    _origin = details.globalPosition;
  }

  void _update(DragUpdateDetails details) {
    final travel = _travel + (details.primaryDelta ?? 0);
    if (_origin case final origin?) {
      _drift = (details.globalPosition.dy - origin.dy).abs();
    }
    final armed = _actionAt(travel) != null;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _travel = travel;
      _armed = armed;
    });
  }

  void _end(DragEndDetails _) {
    // Distance alone decides: a fast but short flick is not a swipe action.
    final action = _actionAt(_travel);
    _reset();
    action?.call();
  }

  void _reset() {
    if (mounted) setState(_clear);
  }

  void _clear() {
    _travel = 0;
    _origin = null;
    _drift = 0;
    _armed = false;
    _pointerCancelled = false;
  }

  double get _offset {
    if (_travel > 0 && _complete != null) {
      return _travel.clamp(0, _maximumReveal);
    }
    if (_travel < 0 && _schedule != null) {
      return _travel.clamp(-_maximumReveal, 0);
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final offset = _offset;
    final colors = Theme.of(context).colorScheme;
    // The structure stays the same at rest and while swiping so the row's
    // own state (focus, ink, menus) survives every gesture.
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        if (_complete != null || _schedule != null)
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(
                () => HorizontalDragGestureRecognizer(
                  debugOwner: this,
                  supportedDevices: _touchOnly,
                ),
                (recognizer) => recognizer
                  // Count the travel from the touch-down point, so the
                  // distance that won the arena is not lost.
                  ..dragStartBehavior = DragStartBehavior.down
                  ..onStart = _start
                  ..onUpdate = _update
                  ..onEnd = _end
                  ..onCancel = _reset,
              ),
      },
      // Pointer listeners run before the gesture arena sees the same event.
      child: Listener(
        onPointerDown: (_) => _pointerCancelled = false,
        onPointerCancel: (_) => _pointerCancelled = true,
        child: Stack(
          // The row keeps exactly the constraints it had without the wrapper.
          fit: StackFit.passthrough,
          children: <Widget>[
            Positioned.fill(
              child: offset == 0
                  ? const SizedBox.shrink()
                  : _SwipeBackground(
                      completing: offset > 0,
                      armed: _armed,
                      colors: colors,
                    ),
            ),
            Transform.translate(
              offset: Offset(offset, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: offset == 0 ? Colors.transparent : colors.surface,
                ),
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.completing,
    required this.armed,
    required this.colors,
  });

  final bool completing;
  final bool armed;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final background = completing
        ? (armed ? colors.primary : colors.primaryContainer)
        : (armed ? colors.tertiary : colors.tertiaryContainer);
    final foreground = completing
        ? (armed ? colors.onPrimary : colors.onPrimaryContainer)
        : (armed ? colors.onTertiary : colors.onTertiaryContainer);
    return ExcludeSemantics(
      child: ColoredBox(
        color: background,
        child: Align(
          alignment: completing ? Alignment.centerLeft : Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Icon(
              completing ? Icons.check : Icons.event_outlined,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of the quick-scheduling sheet.
enum QuickDateAction {
  today(DateShortcut.today, 'Today', Icons.today),
  tomorrow(DateShortcut.tomorrow, 'Tomorrow', Icons.wb_sunny_outlined),
  nextWeek(DateShortcut.nextWeek, 'Next week', Icons.next_week_outlined),
  nextMonth(
    DateShortcut.nextMonth,
    'Next month',
    Icons.calendar_month_outlined,
  ),
  chooseDate(null, 'Choose date', Icons.edit_calendar_outlined),
  clear(DateShortcut.clear, 'Clear date', Icons.event_busy_outlined);

  const QuickDateAction(this.shortcut, this.label, this.icon);

  /// The shared date shortcut this entry applies; null for [chooseDate],
  /// which opens the date dialog instead of writing a date.
  final DateShortcut? shortcut;
  final String label;
  final IconData icon;
}

/// Shows quick scheduling for the task titled [taskTitle] and returns the
/// chosen action, or null when the sheet is dismissed without a choice.
///
/// The sheet only reports a choice; the caller applies it to the exact task
/// it captured when the swipe ended, so a list that changes underneath the
/// sheet can never redirect the date to another row.
Future<QuickDateAction?> showQuickDateSheet(
  BuildContext context, {
  required String taskTitle,
}) async {
  final navigation = AppNavigationScope.maybeOf(context);
  navigation?.dialogOpened(AppDialogKind.date);
  try {
    return await showModalBottomSheet<QuickDateAction>(
      context: context,
      // Above the shell's banners and app bars.
      useRootNavigator: true,
      showDragHandle: true,
      // Six options and a heading can exceed the default height on a short
      // landscape phone or at large text; the list scrolls instead.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          key: const Key('quick-date-sheet'),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'Schedule “$taskTitle”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                for (final action in QuickDateAction.values)
                  ListTile(
                    key: Key('quick-date-${action.name}'),
                    leading: Icon(action.icon),
                    title: Text(action.label),
                    onTap: () => Navigator.of(sheetContext).pop(action),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  } finally {
    navigation?.dialogClosed(AppDialogKind.date);
  }
}
