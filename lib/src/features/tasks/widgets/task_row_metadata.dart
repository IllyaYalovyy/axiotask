import 'package:material_ui/material_ui.dart';

import '../../../domain/policy/task_row_metadata.dart';

/// The phone task row's metadata line: notes, due information, subtask
/// progress and (in a smart view) the task's list, as v1.5.3 showed them.
///
/// Items wrap onto further lines rather than overflow at narrow widths or
/// large text, and each text item ellipsizes within the line. Assistive
/// technology hears one phrase for the whole line
/// ([TaskRowMetadata.spokenLabel]) instead of icons and abbreviations.
final class TaskRowMetadataLine extends StatelessWidget {
  const TaskRowMetadataLine({
    required this.metadata,
    required this.completed,
    super.key,
  });

  final TaskRowMetadata metadata;
  final bool completed;

  static const double iconSize = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      decoration: completed ? TextDecoration.lineThrough : null,
    );
    Color urgencyColor(DueUrgency urgency) => completed
        ? scheme.onSurfaceVariant
        : switch (urgency) {
            DueUrgency.overdue => scheme.error,
            DueUrgency.today => scheme.primary,
            DueUrgency.later => scheme.onSurfaceVariant,
          };
    return Semantics(
      key: const Key('task-row-metadata'),
      container: true,
      label: metadata.spokenLabel,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Every text item may use the whole line before it ellipsizes.
          Widget item({
            required Key key,
            required IconData icon,
            required String text,
            Color? color,
            FontWeight? weight,
            FontStyle? fontStyle,
          }) => ConstrainedBox(
            key: key,
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  icon,
                  size: iconSize,
                  color: color ?? scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted?.copyWith(
                      color: color,
                      fontWeight: weight,
                      fontStyle: fontStyle,
                    ),
                  ),
                ),
              ],
            ),
          );
          return Wrap(
            spacing: 12,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (metadata.hasNotes)
                Icon(
                  Icons.notes,
                  key: const Key('task-row-notes'),
                  size: iconSize,
                  color: scheme.onSurfaceVariant,
                ),
              if (metadata.ownDue case final due?)
                item(
                  key: const Key('task-row-due'),
                  icon: Icons.event,
                  text: due.text,
                  color: urgencyColor(due.urgency),
                  weight: due.urgency == DueUrgency.overdue && !completed
                      ? FontWeight.w600
                      : null,
                ),
              if (metadata.subtaskDue case final due?)
                item(
                  key: const Key('task-row-subtask-due'),
                  icon: Icons.subdirectory_arrow_right,
                  text: due.text,
                  color: urgencyColor(due.urgency),
                  fontStyle: FontStyle.italic,
                ),
              if (metadata.isUndated)
                Text(
                  'no date',
                  key: const Key('task-row-no-date'),
                  maxLines: 1,
                  style: muted,
                ),
              if (metadata.progress case final progress?)
                Row(
                  key: const Key('task-row-progress'),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 40,
                      child: LinearProgressIndicator(
                        value: progress.fraction,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${progress.completed}/${progress.total}',
                      maxLines: 1,
                      style: muted,
                    ),
                  ],
                ),
              if (metadata.listTitle case final title?)
                item(
                  key: const Key('task-row-list'),
                  icon: Icons.list_alt_outlined,
                  text: title,
                ),
            ],
          );
        },
      ),
    );
  }
}
