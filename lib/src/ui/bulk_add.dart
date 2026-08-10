// BulkAdd — the modal that creates many tasks at once from multi-line text
// (BulkAdd.svelte). Two modes: one task per non-empty line (default), or the
// first line as the title with the rest as notes (a single task). A live count
// preview ("Nothing to add" / "Creates N task(s)") gates the Add button, and a
// list selector picks where the tasks land.
//
// This is also the home of the ported PasteCreate bulk-split: the desktop-web
// global Ctrl+V paste dies, but [splitBulkLines] — one task per non-blank line
// — is exactly the per-line mode here, so a multi-line paste routed to this
// dialog splits identically.

import 'package:flutter/material.dart';

import '../store/stored.dart';

/// Which way [BulkAddDialog] turns its text into tasks.
enum BulkAddMode {
  /// Each non-empty line becomes its own task.
  perLine,

  /// The first line is a single task's title; the remaining lines are its notes.
  titleNotes,
}

/// The user's confirmed bulk-add: the raw [text], the [mode], and the target
/// [listId]. Returned by [showBulkAddDialog]; the caller performs the creates.
class BulkAddResult {
  const BulkAddResult({
    required this.text,
    required this.mode,
    required this.listId,
  });

  final String text;
  final BulkAddMode mode;
  final String listId;
}

/// The non-blank, trimmed lines of [text] — one task per line. Ports the
/// PasteCreate/BulkAdd per-line split so blank lines and surrounding whitespace
/// never create "Untitled" debris.
List<String> splitBulkLines(String text) =>
    text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

/// How many tasks [text] would create in [mode] — drives the live preview and
/// disables Add at zero.
int bulkAddCount(String text, BulkAddMode mode) {
  if (mode == BulkAddMode.titleNotes) {
    return (text.split('\n').first).trim().isEmpty ? 0 : 1;
  }
  return splitBulkLines(text).length;
}

/// Open the BulkAdd dialog prefilled with [initialText], targeting
/// [defaultListId] among [lists]. Resolves to the chosen [BulkAddResult], or
/// `null` when cancelled/dismissed.
Future<BulkAddResult?> showBulkAddDialog(
  BuildContext context, {
  required List<StoredTaskList> lists,
  required String defaultListId,
  String initialText = '',
}) {
  return showDialog<BulkAddResult>(
    context: context,
    builder: (context) => BulkAddDialog(
      lists: lists,
      defaultListId: defaultListId,
      initialText: initialText,
    ),
  );
}

/// The BulkAdd modal. Stateful for the text, mode, and list selection plus the
/// live count.
class BulkAddDialog extends StatefulWidget {
  const BulkAddDialog({
    required this.lists,
    required this.defaultListId,
    this.initialText = '',
    super.key,
  });

  final List<StoredTaskList> lists;
  final String defaultListId;
  final String initialText;

  @override
  State<BulkAddDialog> createState() => _BulkAddDialogState();
}

class _BulkAddDialogState extends State<BulkAddDialog> {
  late final TextEditingController _text;
  late String _listId;
  BulkAddMode _mode = BulkAddMode.perLine;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialText);
    _listId = widget.lists.any((l) => l.list.id == widget.defaultListId)
        ? widget.defaultListId
        : (widget.lists.isEmpty ? '' : widget.lists.first.list.id);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  int get _count => bulkAddCount(_text.text, _mode);

  void _submit() {
    if (_count == 0) return;
    Navigator.of(
      context,
    ).pop(BulkAddResult(text: _text.text, mode: _mode, listId: _listId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _count;
    return AlertDialog(
      title: const Text('Add multiple tasks'),
      content: SizedBox(
        // maxFinite so the dialog sizes to its own inset padding — a fixed
        // width would overflow a ~400dp phone.
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('bulk-add-text'),
              controller: _text,
              autofocus: true,
              minLines: 5,
              maxLines: 10,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Paste or type one task per line…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            RadioGroup<BulkAddMode>(
              groupValue: _mode,
              onChanged: (m) => setState(() => _mode = m!),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<BulkAddMode>(
                    key: Key('bulk-add-mode-per-line'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: BulkAddMode.perLine,
                    title: Text('One task per line'),
                  ),
                  RadioListTile<BulkAddMode>(
                    key: Key('bulk-add-mode-title-notes'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: BulkAddMode.titleNotes,
                    title: Text('First line is the title, the rest are notes'),
                  ),
                ],
              ),
            ),
            if (widget.lists.length > 1) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('List', style: theme.textTheme.labelMedium),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      key: const Key('bulk-add-list'),
                      isExpanded: true,
                      value: _listId.isEmpty ? null : _listId,
                      onChanged: (v) => setState(() => _listId = v!),
                      items: [
                        for (final l in widget.lists)
                          DropdownMenuItem(
                            value: l.list.id,
                            child: Text(l.list.title),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              count == 0
                  ? 'Nothing to add'
                  : 'Creates $count task${count == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
        FilledButton(
          key: const Key('bulk-add-submit'),
          onPressed: count == 0 ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
