// SearchOverlay → the live task search (Dart port of SearchOverlay.svelte).
// A modal box: title+notes substring search over EVERY task (subtasks included),
// open-before-completed ranking, a 20-row cap, and a result set that resets its
// keyboard selection whenever the query narrows or widens. Selecting a result
// hands the task back to the caller; the caller navigates.
//
// Subtasks are never rows in any list (invariant #1), so a matched subtask is
// reached THROUGH its parent: [searchLandingViewId] sends the caller to the
// parent's list, and the subtask's own detail then opens in that context (#92).
//
// Due values are date-only (Google sends midnight UTC); [formatDue] parses the
// calendar Y-M-D into a LOCAL date so a negative-UTC zone never shifts the label
// a day earlier (#76).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/task.dart';
import '../store/stored.dart';
import 'date_format.dart';
import 'state_layer.dart';

/// The list to navigate to when [selected] is opened from search: the list
/// holding its PARENT for a subtask (reached only through its parent — #92),
/// else the list holding the task itself. A subtask whose parent is missing
/// falls back to its own list.
String searchLandingViewId(List<StoredTask> all, StoredTask selected) {
  final parentId = selected.task.parent;
  if (parentId != null) {
    for (final t in all) {
      if (t.task.id == parentId) return t.listId;
    }
  }
  return selected.listId;
}

/// Present the [SearchOverlay] as a modal dialog over [context]. [onSelect] is
/// invoked (after the overlay is dismissed) with the chosen task; the caller
/// navigates. [listTitles] maps a list id to its display title for the chip.
Future<void> showSearchOverlay(
  BuildContext context, {
  required List<StoredTask> tasks,
  required Map<String, String> listTitles,
  required void Function(StoredTask) onSelect,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    pageBuilder: (dialogContext, _, _) => SearchOverlay(
      tasks: tasks,
      listTitles: listTitles,
      // Dismiss first, THEN hand back the task so navigation never runs under
      // an open dialog route.
      onSelect: (t) {
        Navigator.of(dialogContext).pop();
        onSelect(t);
      },
      onClose: () => Navigator.of(dialogContext).pop(),
    ),
  );
}

/// The maximum number of results shown (mirrors the reference's `.slice(0, 20)`).
const int _resultLimit = 20;

/// The live search box. Stateless w.r.t. its inputs — [tasks] is the full task
/// set to search; the widget owns only the query and the keyboard selection.
class SearchOverlay extends StatefulWidget {
  const SearchOverlay({
    required this.tasks,
    required this.listTitles,
    required this.onSelect,
    required this.onClose,
    super.key,
  });

  /// Every task to search — top-level tasks AND subtasks.
  final List<StoredTask> tasks;

  /// List id → display title, for a result's list chip.
  final Map<String, String> listTitles;

  /// Called with the task the user activated (tap or Enter).
  final void Function(StoredTask) onSelect;

  /// Called when the overlay should close without a selection (Escape/scrim).
  final VoidCallback onClose;

  @override
  State<SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends State<SearchOverlay> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();

  // The keyboard-highlighted result index. Reset to 0 on every query change so
  // narrowing/widening can never leave it pointing past the end of the list.
  int _selectedIdx = 0;

  @override
  void dispose() {
    _query.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// The parent title for [task], or null when it is top-level / the parent is
  /// not in the task set.
  String? _parentTitle(StoredTask task) {
    final parentId = task.task.parent;
    if (parentId == null) return null;
    for (final t in widget.tasks) {
      if (t.task.id == parentId) return t.task.title;
    }
    return null;
  }

  /// The ranked, capped results for the current query (empty when the query is
  /// blank). Open tasks sort before completed ones; order is otherwise stable.
  List<StoredTask> get _results {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final matches = <StoredTask>[
      for (final t in widget.tasks)
        if ((t.task.title.toLowerCase().contains(q)) ||
            (t.task.notes?.toLowerCase().contains(q) ?? false))
          t,
    ];
    // Stable open-before-completed sort (mergesort — Dart's List.sort is stable).
    matches.sort((a, b) {
      final ac = a.task.status == TaskStatus.completed ? 1 : 0;
      final bc = b.task.status == TaskStatus.completed ? 1 : 0;
      return ac - bc;
    });
    return matches.length > _resultLimit
        ? matches.sublist(0, _resultLimit)
        : matches;
  }

  void _onQueryChanged() => setState(() => _selectedIdx = 0);

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() {
      _selectedIdx = (_selectedIdx + delta).clamp(0, count - 1);
    });
  }

  void _activate(StoredTask task) => widget.onSelect(task);

  void _activateSelected(List<StoredTask> results) {
    if (results.isEmpty) return;
    final i = _selectedIdx.clamp(0, results.length - 1);
    _activate(results[i]);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final hasQuery = _query.text.trim().isNotEmpty;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _move(1, results.length),
        SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _move(-1, results.length),
      },
      // Respect the soft-keyboard inset (F19 #198): when the on-screen keyboard
      // is up, its height is reported as viewInsets.bottom. Padding the overlay
      // by it keeps the search box and its results ABOVE the keyboard on a phone
      // instead of letting the IME cover the very field being typed into.
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: Align(
            alignment: const Alignment(0, -0.6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: _query,
                        focusNode: _fieldFocus,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: 'Search tasks…',
                          prefixIcon: Icon(Icons.search),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => _onQueryChanged(),
                        onSubmitted: (_) => _activateSelected(results),
                      ),
                      if (results.isNotEmpty)
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 360),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: results.length,
                              itemBuilder: (context, i) => _ResultRow(
                                task: results[i].task,
                                listTitle: widget.listTitles[results[i].listId],
                                parentTitle: _parentTitle(results[i]),
                                selected: i == _selectedIdx,
                                onTap: () => _activate(results[i]),
                              ),
                            ),
                          ),
                        )
                      else if (hasQuery)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('No tasks found'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One search result: the (strikethrough-when-completed) title, a "Subtask"
/// badge + parent title for a subtask, the list chip, and the LOCAL due label.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.task,
    required this.listTitle,
    required this.parentTitle,
    required this.selected,
    required this.onTap,
  });

  final Task task;
  final String? listTitle;
  final String? parentTitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = task.status == TaskStatus.completed;
    final due = formatDue(task.due);
    final isSubtask = task.parent != null;
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : null,
      child: StateLayer(
        onTap: onTap,
        // A comfortable full-width, ≥48dp touch target (touch has no hover).
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    decoration: completed ? TextDecoration.lineThrough : null,
                    color: completed
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ),
              if (isSubtask) ...[
                const SizedBox(width: 8),
                _Chip(label: 'Subtask', outlined: true),
                if (parentTitle != null) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Parent: $parentTitle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
              if (listTitle != null) ...[
                const SizedBox(width: 8),
                // Flexible + ellipsis so a long list title truncates instead of
                // overflowing the row (visible at 1.3× text scale on a phone).
                Flexible(child: _Chip(label: listTitle!)),
              ],
              if (due.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  due,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small pill used for the "Subtask" badge and the list-title chip.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.outlined = false});

  final String label;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: outlined ? null : theme.colorScheme.surfaceContainerHighest,
        border: outlined
            ? Border.all(color: theme.colorScheme.outlineVariant)
            : null,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
