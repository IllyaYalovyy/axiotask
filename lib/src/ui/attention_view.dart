// The "Needs attention" view (#296) — the one place the sync layer's leftovers
// can be seen and fixed.
//
// Three states used to exist with no way to act on them from the app: a row the
// server keeps rejecting (held by the poison cap, #270), a "(conflicted copy)"
// the 412 resolver forked (RFC-009 P3), and a session that has died or a sync
// that is permanently stuck. Each was, at best, one sentence in a status line
// the user could read and do nothing about.
//
// The view is QUIET, and that is a design constraint, not an omission: no
// banner, no dialog, no modal interruption. It appears in the sidebar/drawer
// only while it has something in it, carrying a count badge, and the badge is
// the entire announcement. When everything is clean the view does not exist.
//
// Every entry is an action, and every action is REVERSIBLE through the ordinary
// undo toast (invariant #11's surface) — discarding a change and resolving a
// conflict both destroy something the user might want back, and the toast is
// how this app has always offered that back.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/commands.dart';
import '../app/providers.dart';
import '../model/attention.dart';
import '../model/task.dart' show TaskStatus;
import '../store/stored.dart';
import 'date_format.dart';
import 'empty_state.dart';
import 'guarded_command.dart';
import 'properties.dart';
import 'toast.dart';
import 'views.dart';

/// The width below which a conflict's two versions stack instead of sitting
/// side by side. Two columns of task text need room to stay readable; a phone
/// has none, so it reads them top to bottom instead.
const double kConflictSideBySideWidth = 520;

/// The reason a held row is held, in words that carry nothing internal (#187):
/// the server refused it, and no retry of the same content changes that.
const String kQuarantineReason = 'Google rejected this change';

/// The "Needs attention" pane — the list pane for [kAttentionViewId].
class AttentionView extends ConsumerWidget {
  const AttentionView({required this.onOpenTask, super.key});

  /// Open a task's detail (the row's "Open" action).
  final ValueChanged<String> onOpenTask;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(attentionItemsProvider);
    if (items.isEmpty) {
      // Not an error and not a failure of the view: there is genuinely nothing
      // to repair. The sidebar entry is gone too, so this is only ever seen by
      // someone who was already here when the last item cleared (or who
      // relaunched into a restored route).
      return const EmptyStateView(
        key: Key('attention-empty'),
        viewId: kAttentionViewId,
      );
    }

    return ListView(
      key: const Key('attention-list'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (items.hasHeader) _HeaderCard(items: items),
        if (items.held.isNotEmpty) ...[
          _Heading('Changes Google refused (${items.held.length})'),
          for (final held in items.held)
            _HeldCard(
              key: ValueKey('attention-held-${held.id}'),
              held: held,
              onOpenTask: onOpenTask,
            ),
        ],
        if (items.conflicts.isNotEmpty) ...[
          _Heading('Conflicting copies (${items.conflicts.length})'),
          for (final pair in items.conflicts)
            _ConflictCard(
              key: ValueKey('attention-conflict-${pair.copy.task.id}'),
              pair: pair,
            ),
        ],
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The session/sync header: a dead session, or a permanent failure. One card,
/// whichever it is — they are the same kind of problem to the user ("sync is
/// not working and here is what to do about it") and only one can be true at a
/// time in practice.
class _HeaderCard extends ConsumerWidget {
  const _HeaderCard({required this.items});

  final AttentionItems items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final reauth = items.needsReauth;
    return Card(
      key: const Key('attention-header'),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      color: colors.errorContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  reauth ? Icons.vpn_key_outlined : Icons.sync_problem,
                  size: 20,
                  color: colors.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    reauth
                        ? 'Google session expired'
                        : 'Sync is not going through',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (items.syncMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                items.syncMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (reauth)
                  FilledButton.icon(
                    key: const Key('attention-signin'),
                    onPressed: ref.watch(signInActionProvider),
                    icon: const Icon(Icons.login, size: 16),
                    label: const Text('Sign in again'),
                  )
                else
                  FilledButton.icon(
                    key: const Key('attention-sync-now'),
                    onPressed: () => guardCommand(
                      ref.read(toastControllerProvider),
                      'sync_now',
                      ref.read(refreshActionProvider),
                    ),
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Sync now'),
                  ),
                TextButton(
                  key: const Key('attention-properties'),
                  onPressed: () => showProperties(context),
                  child: const Text('Open Properties'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One row the poison cap is holding: what it is, where it lives, why it is
/// stuck, and the three things that can be done about it.
class _HeldCard extends ConsumerWidget {
  const _HeldCard({required this.held, required this.onOpenTask, super.key});

  final HeldChange held;
  final ValueChanged<String> onOpenTask;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTask = held.task != null;
    final where = isTask
        ? (held.listTitle.isEmpty
              ? kQuarantineReason
              : 'In ${held.listTitle} · $kQuarantineReason')
        : 'List · $kQuarantineReason';
    return _EntryCard(
      title: held.title,
      subtitle: where,
      actions: [
        FilledButton.tonal(
          key: Key('attention-retry-${held.id}'),
          onPressed: () => guardCommand(
            ref.read(toastControllerProvider),
            'sync_now',
            () => ref.read(retryQuarantinedActionProvider)(held.id),
          ),
          child: const Text('Retry'),
        ),
        // A held LIST has no per-row base snapshot to fall back to and no
        // detail to open — retrying is genuinely all there is, so nothing else
        // is offered rather than offered and inert.
        if (isTask) ...[
          TextButton(
            key: Key('attention-discard-${held.id}'),
            onPressed: () => _discard(context, ref),
            child: const Text('Discard local change'),
          ),
          TextButton(
            key: Key('attention-open-${held.id}'),
            onPressed: () => onOpenTask(held.id),
            child: const Text('Open'),
          ),
        ],
      ],
    );
  }

  Future<void> _discard(BuildContext context, WidgetRef ref) async {
    final commands = ref.read(commandsProvider);
    final toasts = ref.read(toastControllerProvider);
    DiscardToken? token;
    await guardCommand(toasts, 'discard_change', () async {
      token = await commands.discardLocalChange(held.id);
    });
    final undo = token;
    if (undo == null) return;
    toasts.showUndo(
      'Discarded your change to “${held.title}”',
      () => guardCommand(
        toasts,
        'discard_change',
        () => commands.undoDiscardLocalChange(undo),
      ),
    );
  }
}

/// One unresolved fork: Google's row and the user's, side by side where there
/// is room, and the three ways out.
class _ConflictCard extends ConsumerWidget {
  const _ConflictCard({required this.pair, super.key});

  final ConflictedPair pair;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theirs = _Version(
      label: 'On Google',
      row: pair.original,
      other: pair.copy,
      stripMarker: false,
    );
    final mine = _Version(
      label: 'Your version',
      row: pair.copy,
      other: pair.original,
      stripMarker: true,
    );
    return _EntryCard(
      // The canonical row's title — it never carried the marker.
      title: pair.title,
      subtitle: 'Edited in two places — both copies were kept',
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < kConflictSideBySideWidth) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [theirs, const SizedBox(height: 12), mine],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: theirs),
              const SizedBox(width: 16),
              Expanded(child: mine),
            ],
          );
        },
      ),
      actions: [
        FilledButton.tonal(
          key: Key('attention-keep-mine-${pair.copy.task.id}'),
          onPressed: () => _resolve(context, ref, ConflictChoice.keepMine),
          child: const Text('Keep mine'),
        ),
        TextButton(
          key: Key('attention-keep-theirs-${pair.copy.task.id}'),
          onPressed: () => _resolve(context, ref, ConflictChoice.keepTheirs),
          child: const Text('Keep theirs'),
        ),
        TextButton(
          key: Key('attention-keep-both-${pair.copy.task.id}'),
          onPressed: () => _resolve(context, ref, ConflictChoice.keepBoth),
          child: const Text('Keep both'),
        ),
      ],
    );
  }

  Future<void> _resolve(
    BuildContext context,
    WidgetRef ref,
    ConflictChoice choice,
  ) async {
    final commands = ref.read(commandsProvider);
    final toasts = ref.read(toastControllerProvider);
    ConflictToken? token;
    await guardCommand(toasts, 'resolve_conflict', () async {
      token = await commands.resolveConflict(
        originalId: pair.original.task.id,
        copyId: pair.copy.task.id,
        choice: choice,
      );
    });
    final undo = token;
    if (undo == null) return;
    toasts.showUndo(
      switch (choice) {
        ConflictChoice.keepMine => 'Kept your version',
        ConflictChoice.keepTheirs => "Kept Google's version",
        ConflictChoice.keepBoth => 'Kept both copies',
      },
      () => guardCommand(
        toasts,
        'resolve_conflict',
        () => commands.undoResolveConflict(undo),
      ),
    );
  }
}

/// One side of a conflict: the fields that DIFFER between the two rows, so the
/// user reads the disagreement rather than the whole task twice.
class _Version extends StatelessWidget {
  const _Version({
    required this.label,
    required this.row,
    required this.other,
    required this.stripMarker,
  });

  final String label;
  final StoredTask row;
  final StoredTask other;

  /// Whether to take the "(conflicted copy)" marker off the title before
  /// showing it — it is the app's word, and repeating it in the comparison
  /// would read as a difference the user made.
  final bool stripMarker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = stripMarker
        ? strippedCopyTitle(row.task.title)
        : row.task.title;
    final otherTitle = stripMarker
        ? other.task.title
        : strippedCopyTitle(other.task.title);
    final fields = <(String, String)>[
      if (title != otherTitle) ('Title', title),
      if (row.task.due != other.task.due)
        (
          'Due',
          formatDue(row.task.due).isEmpty
              ? 'No due date'
              : formatDue(row.task.due),
        ),
      if ((row.task.notes ?? '') != (other.task.notes ?? ''))
        ('Notes', (row.task.notes ?? '').isEmpty ? '—' : row.task.notes!),
      if (row.task.status != other.task.status)
        (
          'Status',
          row.task.status == TaskStatus.completed
              ? 'Completed'
              : 'Not completed',
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (fields.isEmpty)
            Text(
              'Same content',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            )
          else
            // Label and value as two plain [Text]s rather than one rich span:
            // the label is dimmed and the value is the user's own words, and a
            // screen reader reads them as "Title, Buy milk" instead of one run.
            for (final (name, value) in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$name: ',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// The shared shape of an entry: title, one explanatory line, an optional body,
/// and a wrapped row of actions (which wraps rather than overflowing — three
/// buttons do not fit a phone in one line at a large text scale).
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.title,
    required this.subtitle,
    required this.actions,
    this.body,
  });

  final String title;
  final String subtitle;
  final Widget? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (body != null) ...[const SizedBox(height: 12), body!],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: actions),
          ],
        ),
      ),
    );
  }
}
