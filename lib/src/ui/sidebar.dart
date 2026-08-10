// The real sidebar — the desktop navigation panel that replaces the plain
// NavigationRail (the T6.2 footer's integration target). It stacks three
// sections the reference Sidebar.svelte owns: the five smart views with their
// count badges, the user's lists (with counts, per-list management, exclusion,
// and drag reorder), and the auth/sync footer pinned at the bottom.
//
// Fresh Material 3 visuals (Q3), not a pixel port of the Tauri sidebar. It is a
// PRESENTATIONAL widget: every piece of state and every action is injected, so
// the whole surface is widget-tested without a store or a router. List
// management is reached through a per-row overflow menu (not a right-click
// context menu) so a coarse pointer has the same reach as a mouse — touch has
// no hover (non-negotiable). Delete routes through a styled confirm dialog, not
// a silent action (no undo for a list, matching the reference).

import 'package:flutter/material.dart';

import '../store/stored.dart';
import 'views.dart';

/// The adaptive navigation sidebar.
class Sidebar extends StatelessWidget {
  const Sidebar({
    required this.selectedViewId,
    required this.counts,
    required this.lists,
    required this.excludedLists,
    required this.onSelectView,
    required this.onCreateList,
    required this.onRenameList,
    required this.onDeleteList,
    required this.onToggleExclude,
    required this.onReorderLists,
    this.footer,
    super.key,
  });

  /// The active view id (a smart-view id or a list id).
  final String selectedViewId;

  /// Badge counts keyed by view id (smart views + list ids). A missing or zero
  /// entry renders no badge.
  final Map<String, int> counts;

  /// The lists to show, already in display order.
  final List<StoredTaskList> lists;

  /// List ids currently excluded from the smart views (rendered dimmed).
  final Set<String> excludedLists;

  /// Select a view by id.
  final ValueChanged<String> onSelectView;

  /// Create a list titled [String], `localOnly` when the second arg is true.
  final void Function(String title, {bool localOnly}) onCreateList;

  /// Rename list `id` to `title`.
  final void Function(String id, String title) onRenameList;

  /// Delete list `id` (after the sidebar's own confirm dialog).
  final ValueChanged<String> onDeleteList;

  /// Toggle a list's smart-view exclusion.
  final ValueChanged<String> onToggleExclude;

  /// The full list-id order after a drag reorder.
  final ValueChanged<List<String>> onReorderLists;

  /// The auth/sync footer, pinned at the bottom. `null` hides it (auth wiring
  /// pending).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ReorderableListView(
              key: const Key('sidebar-lists-reorderable'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              buildDefaultDragHandles: false,
              header: _Header(
                selectedViewId: selectedViewId,
                counts: counts,
                hasLists: lists.isNotEmpty,
                onSelectView: onSelectView,
                onCreateList: () => _createList(context),
              ),
              onReorderItem: _onReorder,
              children: [
                for (var i = 0; i < lists.length; i++)
                  _ListRow(
                    key: ValueKey(lists[i].list.id),
                    index: i,
                    stored: lists[i],
                    selected: lists[i].list.id == selectedViewId,
                    excluded: excludedLists.contains(lists[i].list.id),
                    count: counts[lists[i].list.id] ?? 0,
                    onSelect: () => onSelectView(lists[i].list.id),
                    onRename: () => _renameList(context, lists[i]),
                    onDelete: () => _deleteList(context, lists[i]),
                    onToggleExclude: () => onToggleExclude(lists[i].list.id),
                  ),
              ],
            ),
          ),
          if (footer != null) ...[const Divider(height: 1), footer!],
        ],
      ),
    );
  }

  // [onReorderItem] hands back a newIndex already adjusted for the item removed
  // at oldIndex, so no manual `newIndex -= 1` shift is needed.
  void _onReorder(int oldIndex, int newIndex) {
    final order = [for (final l in lists) l.list.id];
    final moved = order.removeAt(oldIndex);
    order.insert(newIndex, moved);
    onReorderLists(order);
  }

  Future<void> _createList(BuildContext context) async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => const _NewListDialog(),
    );
    if (result == null) return;
    final (title, localOnly) = result;
    if (title.isEmpty) return;
    onCreateList(title, localOnly: localOnly);
  }

  Future<void> _renameList(BuildContext context, StoredTaskList l) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameListDialog(initial: l.list.title),
    );
    if (title == null || title.isEmpty || title == l.list.title) return;
    onRenameList(l.list.id, title);
  }

  Future<void> _deleteList(BuildContext context, StoredTaskList l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        key: const Key('delete-list-confirm'),
        title: const Text('Delete list'),
        content: Text(
          'Delete "${l.list.title}" and all its tasks? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('delete-list-confirm-button'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) onDeleteList(l.list.id);
  }
}

/// The non-reorderable header: the smart views plus the "Lists" section title
/// and its add button. Lives in [ReorderableListView.header] so only the list
/// rows below it drag.
class _Header extends StatelessWidget {
  const _Header({
    required this.selectedViewId,
    required this.counts,
    required this.hasLists,
    required this.onSelectView,
    required this.onCreateList,
  });

  final String selectedViewId;
  final Map<String, int> counts;
  final bool hasLists;
  final ValueChanged<String> onSelectView;
  final VoidCallback onCreateList;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in SmartView.values)
          _NavRow(
            icon: v.icon,
            selectedIcon: v.selectedIcon,
            label: v.label,
            selected: v.id == selectedViewId,
            count: counts[v.id] ?? 0,
            onTap: () => onSelectView(v.id),
          ),
        const SizedBox(height: 8),
        const Divider(height: 1, indent: 12, endIndent: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Lists',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const Key('sidebar-add-list'),
                tooltip: 'New list',
                icon: const Icon(Icons.add, size: 20),
                onPressed: onCreateList,
              ),
            ],
          ),
        ),
        if (!hasLists)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              'No lists',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// One selectable navigation row (a smart view or, without the trailing slot, a
/// list). Highlighted when [selected]; shows a [count] badge when it is > 0.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 20,
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                _CountBadge(count: count),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A list row: selectable, dimmed when excluded, with a drag handle and an
/// overflow menu (rename / delete / exclude).
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.index,
    required this.stored,
    required this.selected,
    required this.excluded,
    required this.count,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onToggleExclude,
    super.key,
  });

  final int index;
  final StoredTaskList stored;
  final bool selected;
  final bool excluded;
  final int count;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onToggleExclude;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onSelect,
          child: Opacity(
            opacity: excluded ? 0.5 : 1,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Icon(
                      Icons.drag_indicator,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    stored.localOnly
                        ? Icons.cloud_off_outlined
                        : Icons.list_alt_outlined,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      stored.list.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontStyle: excluded ? FontStyle.italic : null,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected
                            ? colors.onSecondaryContainer
                            : colors.onSurface,
                      ),
                    ),
                  ),
                  _CountBadge(count: count),
                  _ListMenu(
                    excluded: excluded,
                    onRename: onRename,
                    onDelete: onDelete,
                    onToggleExclude: onToggleExclude,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The per-list overflow menu (touch- and mouse-reachable alike).
class _ListMenu extends StatelessWidget {
  const _ListMenu({
    required this.excluded,
    required this.onRename,
    required this.onDelete,
    required this.onToggleExclude,
  });

  final bool excluded;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onToggleExclude;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'List actions',
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (v) {
        switch (v) {
          case 'rename':
            onRename();
          case 'delete':
            onDelete();
          case 'exclude':
            onToggleExclude();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(
          value: 'exclude',
          child: Text(
            excluded ? 'Include in smart views' : 'Exclude from smart views',
          ),
        ),
        const PopupMenuItem(value: 'delete', child: Text('Delete list')),
      ],
    );
  }
}

/// A small count pill; renders nothing when [count] is zero.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The new-list dialog: a name field and a local-only checkbox. Returns
/// `(trimmedTitle, localOnly)` or null on cancel.
class _NewListDialog extends StatefulWidget {
  const _NewListDialog();

  @override
  State<_NewListDialog> createState() => _NewListDialogState();
}

class _NewListDialogState extends State<_NewListDialog> {
  final _controller = TextEditingController();
  bool _localOnly = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() =>
      Navigator.pop(context, (_controller.text.trim(), _localOnly));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('new-list-dialog'),
      title: const Text('New list'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'List name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const Key('new-list-local-only'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _localOnly,
            onChanged: (v) => setState(() => _localOnly = v ?? false),
            title: const Text('Local only (never synced to Google)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('new-list-create'),
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// The rename-list dialog. Returns the trimmed new title or null on cancel.
class _RenameListDialog extends StatefulWidget {
  const _RenameListDialog({required this.initial});

  final String initial;

  @override
  State<_RenameListDialog> createState() => _RenameListDialogState();
}

class _RenameListDialogState extends State<_RenameListDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('rename-list-dialog'),
      title: const Text('Rename list'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'List name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('rename-list-save'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
