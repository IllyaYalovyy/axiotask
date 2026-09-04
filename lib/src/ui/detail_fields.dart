// The detail panel's FIELD ROWS (#274, split out of task_detail.dart): the
// subtask breadcrumb, the due-date field, the due+list pair, the list dropdown,
// and the detected-link chips.
//
// Each is a pure presentation widget over values and callbacks the panel owns —
// none of them reads a provider or writes a task — so the panel is left holding
// the editing state and these hold the layout of one row apiece.

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;
import '../store/stored.dart';
import 'date_format.dart';
import 'quick_date_menu.dart';
import 'theme.dart';
import 'url_opener.dart';

/// The subtask breadcrumb ("← Parent") atop a subtask's own panel — the way
/// back up, and nothing else: detaching is an action, and every action lives in
/// the app-bar overflow (#246), so no button outranks the title.
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({
    super.key,
    required this.parentTitle,
    required this.onOpenParent,
  });

  final String parentTitle;
  final VoidCallback onOpenParent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onOpenParent,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: Text(
            parentTitle.isEmpty ? 'Parent task' : parentTitle,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// The task's own due date: one field that raises the ONE shared quick-date
/// option set (#243) — Today · Tomorrow · Next week · Next month ·
/// Pick a date… · Clear.
///
/// It used to be a calendar button with its OWN chip row beneath it, worded
/// "+1 week" / "+1 month" — a second vocabulary for the moves the rest of the
/// app called "Next week" / "Next month", and one that could not reach the
/// calendar or a clear without leaving the chips. One control, one list.
///
/// The date itself wears the SHARED urgency tone (#242) — the same colour the
/// row's due badge and the Focus "Overdue (N)" heading use — so opening a task
/// never changes what its date's colour means. The outline stays neutral: the
/// urgency is a property of the DATE, not of the control around it.
class DueField extends StatelessWidget {
  const DueField({
    super.key,
    required this.due,
    required this.onPick,
    required this.onQuick,
  });

  final String? due;

  /// Open the calendar ("Pick a date…").
  final VoidCallback onPick;

  /// Apply a frozen move from the shared menu.
  final ValueChanged<DateMove> onQuick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final has = (due ?? '').isNotEmpty;
    final label = has ? formatDue(due) : 'No date';
    final urgency = has ? dueUrgency(due) : DueUrgency.none;
    final color = dueColor(urgency, theme.colorScheme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Due date', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        QuickDateAnchor(
          onSetDue: onQuick,
          onPickDate: onPick,
          builder: (context, open) => OutlinedButton.icon(
            key: const Key('due-field'),
            onPressed: open,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label.isEmpty ? 'No date' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // Semibold on overdue only — the same emphasis the row's badge
                // carries, so the two surfaces read as one signal.
                style: TextStyle(
                  color: color,
                  fontWeight: urgency == DueUrgency.overdue
                      ? FontWeight.w600
                      : null,
                ),
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size.fromHeight(44),
              alignment: Alignment.centerLeft,
            ),
          ),
        ),
      ],
    );
  }
}

/// The Due-date and List pair. They are the panel's two structured fields and
/// are edited together, so on a wide panel they share ONE compact line and the
/// notes stay above the fold; below [_sideBySide] there is no honest room for
/// two controls, and they stack — Due first.
class DueAndList extends StatelessWidget {
  const DueAndList({super.key, required this.due, required this.list});

  final Widget due;

  /// `null` for a subtask, which has no List field at all (#93) — the Due field
  /// then simply takes the full width.
  final Widget? list;

  /// Below this the two controls would each be narrower than a date reads. It
  /// is scaled by the ambient text scale: at 1.3x the same pixels hold less
  /// text, so a surface that fits both at 1.0x correctly stacks them instead of
  /// ellipsising a list name away.
  static const double _sideBySide = 480;

  @override
  Widget build(BuildContext context) {
    final list = this.list;
    if (list == null) return due;
    final threshold = MediaQuery.textScalerOf(context).scale(_sideBySide);
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= threshold
          ? Row(
              // The two controls have different intrinsic heights (a button vs
              // a decorated dropdown); aligning their BOTTOMS keeps the tappable
              // edges on one line.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: due),
                const SizedBox(width: 12),
                Expanded(child: list),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [due, const SizedBox(height: 16), list],
            ),
    );
  }
}

/// The top-level task's List dropdown — a subtask never renders this (#93).
class ListDropdown extends StatelessWidget {
  const ListDropdown({
    super.key,
    required this.value,
    required this.lists,
    required this.onChanged,
  });

  final String value;
  final List<StoredTaskList> lists;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ids = {for (final l in lists) l.list.id};
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'List',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('list-dropdown'),
          value: ids.contains(value) ? value : null,
          isExpanded: true,
          items: [
            for (final l in lists)
              DropdownMenuItem(
                value: l.list.id,
                child: Text(
                  l.list.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null && v != value) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// The clickable links found in the task's title/notes.
class Links extends StatelessWidget {
  const Links({super.key, required this.urls, required this.onOpen});

  final List<String> urls;
  final UrlOpener onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Links', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        for (final url in urls)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('link-$url'),
              onPressed: () => onOpen(url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    );
  }
}
