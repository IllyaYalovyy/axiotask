// The two modal pickers of the T7.6 action surface:
//
//   • [showMoveToListPicker] — MoveToListPicker.svelte: pick a destination list.
//     Single-task mode hides the task's current list; bulk mode shows them all.
//   • [showParentPicker] — ParentPicker.svelte: the searchable "Make subtask
//     of…" picker (#88). Candidates are the legal parents (childless top-level
//     tasks in the same list, computed by the caller via canNestUnder); a
//     type-to-filter narrows by title and the highlight resets to the first
//     result on every change (can't point past the end).
//
// The arrow/Enter keyboard navigation dies with the keyboard layer; tap-to-
// select and dismiss (barrier tap) port. Rows are comfortably tall so a coarse
// pointer hits them.

import 'package:flutter/material.dart';

import '../store/stored.dart';

/// Pick a destination list among [lists], excluding [currentListId] when given
/// (single move). Resolves to the chosen list id, or `null` when dismissed.
Future<String?> showMoveToListPicker(
  BuildContext context, {
  required List<StoredTaskList> lists,
  String? currentListId,
}) {
  final options = lists
      .where((l) => l.list.id != currentListId)
      .toList(growable: false);
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Move to list'),
      children: [
        for (final l in options)
          SimpleDialogOption(
            key: Key('move-picker-${l.list.id}'),
            onPressed: () => Navigator.of(context).pop(l.list.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l.list.title),
            ),
          ),
        if (options.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No other lists'),
          ),
      ],
    ),
  );
}

/// Open the searchable "Make subtask of…" picker over [candidates] (the legal
/// parents, pre-filtered by the caller). Resolves to the chosen parent id, or
/// `null` when dismissed.
Future<String?> showParentPicker(
  BuildContext context, {
  required List<StoredTask> candidates,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ParentPickerDialog(candidates: candidates),
  );
}

class _ParentPickerDialog extends StatefulWidget {
  const _ParentPickerDialog({required this.candidates});

  final List<StoredTask> candidates;

  @override
  State<_ParentPickerDialog> createState() => _ParentPickerDialogState();
}

class _ParentPickerDialogState extends State<_ParentPickerDialog> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<StoredTask> get _results {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return widget.candidates
        .where((t) => t.task.title.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return AlertDialog(
      title: const Text('Make subtask of…'),
      content: SizedBox(
        // maxFinite so the picker fits a phone's dialog width (a fixed 420
        // would overflow a ~400dp screen).
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('parent-picker-query'),
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search for a parent task…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: results.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No matching task'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in results)
                          ListTile(
                            key: Key('parent-picker-${t.task.id}'),
                            dense: true,
                            title: Text(
                              t.task.title.isEmpty
                                  ? 'Untitled task'
                                  : t.task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(t.task.id),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
