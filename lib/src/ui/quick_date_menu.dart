// The ONE quick-date surface (#243). Every place in the app where a due date is
// set — a task row's date / "no date" segment, a swipe-left on a row, the detail
// panel's Due field and each subtask's due button, the bulk bar's "Due ▾", the
// row action menu's "Set due date" submenu and the composer's date button —
// offers the SAME options, in the SAME order, with the SAME wording.
//
// Before this there were four vocabularies for one concept ("1 wk" / "Next week"
// / "+1 week"), three affordances, and a row date tap that skipped the quick
// options entirely and went straight to the calendar. The user's ruling
// (2026-08-30) was "that has to be unified", and the option set is FROZEN:
//
//     Today · Tomorrow · Next week · Next month · Pick a date… · Clear
//
// Every move is relative to TODAY ([applyDateMove]) — "Next week" is today + 7
// days, never "next Monday" and never "the current due + 7". Custom dates go
// through "Pick a date…", which opens the calendar. Nothing else is added here
// without a new user ruling; one item added to [kQuickDateItems] appears on
// every surface at once, which is the point of the component.
//
// Presentation adapts to the POINTER, never to the window width: a fine pointer
// gets an anchored [MenuAnchor] (Escape and a click outside dismiss it, focus
// returns to the anchor), a coarse pointer gets a modal bottom sheet on the ROOT
// navigator (#234 — a sheet on the shell's nested navigator renders under the
// FAB and the nav bar). Same items, same order, same icons.

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;
import 'theme.dart' show coarsePointerPlatform;

/// One entry of the frozen quick-date option set.
class QuickDateItem {
  const QuickDateItem({
    required this.id,
    required this.label,
    required this.icon,
    this.move,
  });

  /// Stable id behind this item's widget [Key] — `quick-date-menu-<id>` in the
  /// menu/sheet, `taskmenu-due-<id>` in the row action menu's submenu.
  final String id;

  /// The one wording this option has anywhere in the app.
  final String label;

  final IconData icon;

  /// The date move this item applies, or `null` for "Pick a date…" — the only
  /// item that opens the calendar instead of writing a date.
  final DateMove? move;
}

/// The FROZEN quick-date option set, in order (user ruling 2026-08-30, #243).
/// The single source of every quick-date list the app renders.
const List<QuickDateItem> kQuickDateItems = [
  QuickDateItem(
    id: 'today',
    label: 'Today',
    icon: Icons.today,
    move: DateMove.today,
  ),
  QuickDateItem(
    id: 'tomorrow',
    label: 'Tomorrow',
    icon: Icons.wb_sunny_outlined,
    move: DateMove.tomorrow,
  ),
  QuickDateItem(
    id: 'week',
    label: 'Next week',
    icon: Icons.next_week_outlined,
    move: DateMove.nextWeek,
  ),
  QuickDateItem(
    id: 'month',
    label: 'Next month',
    icon: Icons.calendar_month_outlined,
    move: DateMove.nextMonth,
  ),
  QuickDateItem(
    id: 'pick',
    label: 'Pick a date…',
    icon: Icons.calendar_today_outlined,
  ),
  QuickDateItem(
    id: 'clear',
    label: 'Clear',
    icon: Icons.event_busy_outlined,
    move: DateMove.clear,
  ),
];

/// The widget [Key] of [id]'s entry in the anchored menu / bottom sheet.
Key quickDateKey(String id) => Key('quick-date-menu-$id');

/// Run [item]: a move goes to [onSetDue], "Pick a date…" goes to [onPickDate].
void _invoke(
  QuickDateItem item,
  ValueChanged<DateMove> onSetDue,
  VoidCallback onPickDate,
) {
  final move = item.move;
  if (move == null) {
    onPickDate();
  } else {
    onSetDue(move);
  }
}

/// Show the coarse-pointer presentation: a modal bottom sheet carrying the
/// frozen option set, on the ROOT navigator so it layers above the shell's FAB
/// and navigation bar (#234). Also the surface a swipe-left on a task row
/// opens, so the gesture and the tap lead to exactly the same choices.
Future<void> showQuickDateSheet(
  BuildContext context, {
  required ValueChanged<DateMove> onSetDue,
  required VoidCallback onPickDate,
  String title = 'Due date',
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    // Six 48dp+ options plus a heading are taller than the default sheet's
    // 9/16-of-the-screen ceiling on a short viewport (a landscape phone, a
    // small window): scroll-controlled and capped, the list scrolls instead of
    // overflowing and losing "Clear" off the bottom.
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      // The composer's own sheet can be open with the keyboard up when this one
      // is raised over it; a sheet that ignores the IME inset draws its last
      // options behind the keyboard where no finger reaches them (#166).
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    title,
                    style: Theme.of(sheetContext).textTheme.titleSmall,
                  ),
                ),
                for (final item in kQuickDateItems)
                  ListTile(
                    key: quickDateKey(item.id),
                    leading: Icon(item.icon),
                    title: Text(item.label),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      // Run once the sheet is gone, so "Pick a date…" opening the
                      // calendar does not fight the dismissal (the action-sheet
                      // pattern in task_actions.dart).
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _invoke(item, onSetDue, onPickDate),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A quick-date affordance: [builder] draws whatever the surface's own control
/// is (a row's date segment, the detail's Due field, the bulk bar's "Due ▾",
/// the composer's date button) and calls the `open` callback it is handed to
/// raise the shared option set.
///
/// A fine pointer opens an anchored [MenuAnchor] beneath the control; a coarse
/// pointer opens [showQuickDateSheet]. The anchor owns the focus node the menu
/// returns focus to when it closes, so an Escape on the desktop lands the caret
/// back on the control that opened it.
class QuickDateAnchor extends StatefulWidget {
  const QuickDateAnchor({
    required this.onSetDue,
    required this.onPickDate,
    required this.builder,
    this.sheetTitle = 'Due date',
    this.focusNode,
    super.key,
  });

  /// Apply a frozen move (Today / Tomorrow / Next week / Next month / Clear).
  final ValueChanged<DateMove> onSetDue;

  /// Open the calendar ("Pick a date…").
  final VoidCallback onPickDate;

  /// Draw the control; call `open` to raise the menu/sheet.
  final Widget Function(BuildContext context, VoidCallback open) builder;

  /// The heading of the coarse-pointer sheet.
  final String sheetTitle;

  /// The node focus returns to when an anchored menu closes. Supplied by a
  /// caller that wants to observe it; otherwise the anchor owns one.
  final FocusNode? focusNode;

  @override
  State<QuickDateAnchor> createState() => _QuickDateAnchorState();
}

class _QuickDateAnchorState extends State<QuickDateAnchor> {
  FocusNode? _owned;

  FocusNode get _node => widget.focusNode ?? (_owned ??= FocusNode());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (coarsePointerPlatform(Theme.of(context).platform)) {
      // No hover, no anchored menu: the sheet is the touch presentation, and it
      // must sit on the root navigator (#234).
      return Builder(
        builder: (context) => widget.builder(
          context,
          () => showQuickDateSheet(
            context,
            onSetDue: widget.onSetDue,
            onPickDate: widget.onPickDate,
            title: widget.sheetTitle,
          ),
        ),
      );
    }
    return MenuAnchor(
      // The control the menu hangs off and hands focus back to on close.
      childFocusNode: _node,
      menuChildren: [
        for (final item in kQuickDateItems)
          MenuItemButton(
            key: quickDateKey(item.id),
            leadingIcon: Icon(item.icon, size: 20),
            onPressed: () => _invoke(item, widget.onSetDue, widget.onPickDate),
            child: Text(item.label),
          ),
      ],
      builder: (context, controller, _) => Focus(
        focusNode: _node,
        // Programmatically focusable (that is how the menu hands the caret
        // back on close) but NOT a tab stop of its own: the control the
        // builder draws keeps its place in the traversal order, unduplicated.
        skipTraversal: true,
        child: widget.builder(
          context,
          () => controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}
