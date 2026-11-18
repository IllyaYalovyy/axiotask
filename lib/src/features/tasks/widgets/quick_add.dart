import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../domain/model/tasks.dart';
import '../../../domain/policy/date_workflow.dart';
import '../quick_add_view_model.dart';

final class QuickAddBar extends StatefulWidget {
  const QuickAddBar({
    required this.viewModel,
    required this.lists,
    required this.focusNode,
    this.onPasteMultiple,
    super.key,
  });

  final QuickAddViewModel viewModel;
  final List<CachedTaskList> lists;
  final FocusNode focusNode;
  final VoidCallback? onPasteMultiple;

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

final class _QuickAddBarState extends State<QuickAddBar> {
  late final TextEditingController _controller = TextEditingController();
  bool _optionsOpen = false;
  String? _focusRestoredFor;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) {
      final state = widget.viewModel.state;
      final completion = state.successMessage ?? state.failureMessage;
      final focusRestoreKey = completion == null
          ? null
          : '$completion:${state.input}';
      if (focusRestoreKey != null && _focusRestoredFor != focusRestoreKey) {
        _focusRestoredFor = focusRestoreKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.focusNode.requestFocus();
        });
      }
      if (_controller.text != state.input) {
        _controller.value = TextEditingValue(
          text: state.input,
          selection: TextSelection.collapsed(offset: state.input.length),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: Semantics(
                      label: 'Task title',
                      textField: true,
                      child: TextField(
                        key: const Key('quick-add-input'),
                        controller: _controller,
                        focusNode: widget.focusNode,
                        maxLength: 1024,
                        maxLines: 1,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          hintText: 'Add a task',
                          counterText: '',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          prefixIcon: Icon(Icons.add_task_outlined, size: 20),
                        ),
                        onChanged: widget.viewModel.setInput,
                        onSubmitted: state.isSubmitting
                            ? null
                            : (_) => unawaited(widget.viewModel.submit()),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (state.destinationRequired) ...<Widget>[
                  _DestinationMenu(
                    compact: constraints.maxWidth < 560,
                    state: state,
                    lists: widget.lists,
                    onSelected: widget.viewModel.selectTarget,
                  ),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  key: const Key('quick-add-options'),
                  tooltip: 'Capture options',
                  visualDensity: VisualDensity.compact,
                  onPressed: state.isSubmitting
                      ? null
                      : () => setState(() => _optionsOpen = !_optionsOpen),
                  icon: Icon(_optionsOpen ? Icons.tune : Icons.tune_outlined),
                ),
                const SizedBox(width: 2),
                SizedBox(
                  height: 40,
                  child: FilledButton(
                    key: const Key('quick-add-submit'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(56, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed:
                        state.isSubmitting ||
                            state.input.trim().isEmpty ||
                            state.targetId == null
                        ? null
                        : () => unawaited(widget.viewModel.submit()),
                    child: state.isSubmitting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Add'),
                  ),
                ),
              ],
            ),
          ),
          if (_optionsOpen) ...<Widget>[
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (!state.destinationRequired)
                  _DestinationMenu(
                    compact: false,
                    state: state,
                    lists: widget.lists,
                    onSelected: widget.viewModel.selectTarget,
                  ),
                _DateMenu(
                  state: state,
                  onSelected: widget.viewModel.selectDueShortcut,
                ),
                if (widget.onPasteMultiple case final onPaste?)
                  TextButton.icon(
                    key: const Key('quick-add-paste-multiple'),
                    onPressed: state.isSubmitting ? null : onPaste,
                    icon: const Icon(Icons.content_paste_outlined, size: 18),
                    label: const Text('Paste multiple'),
                  ),
              ],
            ),
          ],
          _CapturePreview(
            state: state,
            gap: 8,
            onDismissParsedDate: widget.viewModel.dismissDatePreview,
          ),
          _CaptureFeedback(state: state, gap: 6),
        ],
      );
    },
  );
}

/// The capture's interpretation before it is saved: the title to create
/// and the due date, with a chip that dismisses a parsed date. Shared by the
/// desktop bar and the phone composer; [gap] is the space above it.
final class _CapturePreview extends StatelessWidget {
  const _CapturePreview({
    required this.state,
    required this.gap,
    required this.onDismissParsedDate,
  });

  final QuickAddState state;
  final double gap;
  final VoidCallback onDismissParsedDate;

  static bool isVisible(QuickAddState state) =>
      state.input.trim().isNotEmpty &&
      (state.hasParsedDate || state.hasExplicitDue || state.previewDue != null);

  @override
  Widget build(BuildContext context) {
    if (!isVisible(state)) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Semantics(
        liveRegion: true,
        label: 'Quick add preview',
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            Text('Create “${state.previewTitle}”'),
            if (state.previewDue case final due?)
              InputChip(
                avatar: const Icon(Icons.event_outlined, size: 18),
                label: Text('Due $due'),
                tooltip: state.hasParsedDate
                    ? 'Dismiss interpreted date and keep it in the title'
                    : 'Date selected by the visible smart view',
                onDeleted: state.hasParsedDate ? onDismissParsedDate : null,
                // A chip shows its own tooltip only when it is pressable;
                // the dismiss button carries the explanation on touch.
                deleteButtonTooltipMessage:
                    'Dismiss interpreted date and keep it in the title',
                deleteIcon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

/// The outcome of the last capture: why it was rejected, or that it was
/// saved locally. [gap] is the space above each message.
final class _CaptureFeedback extends StatelessWidget {
  const _CaptureFeedback({required this.state, required this.gap});

  final QuickAddState state;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failure = state.failureMessage;
    final success = state.successMessage;
    if (failure == null && success == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (failure != null)
          Padding(
            padding: EdgeInsets.only(top: gap),
            child: Text(
              failure,
              key: const Key('quick-add-failure'),
              style: TextStyle(color: colors.error),
            ),
          ),
        if (success != null)
          Padding(
            padding: EdgeInsets.only(top: gap),
            child: Semantics(
              liveRegion: true,
              child: Text(
                success,
                key: const Key('quick-add-success'),
                style: TextStyle(color: colors.primary),
              ),
            ),
          ),
      ],
    );
  }
}

final class _DestinationMenu extends StatelessWidget {
  const _DestinationMenu({
    required this.compact,
    required this.state,
    required this.lists,
    required this.onSelected,
  });

  final bool compact;
  final QuickAddState state;
  final List<CachedTaskList> lists;
  final ValueChanged<TaskListId> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TaskListId>(
    key: const Key('quick-add-destination'),
    enabled: !state.isSubmitting && lists.isNotEmpty,
    tooltip: 'Destination: ${state.targetName ?? 'No available Google list'}',
    onSelected: onSelected,
    itemBuilder: (context) => <PopupMenuEntry<TaskListId>>[
      for (final list in lists)
        PopupMenuItem<TaskListId>(
          value: list.id,
          child: Text(list.title, overflow: TextOverflow.ellipsis),
        ),
    ],
    child: compact
        ? const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.list_alt_outlined),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.list_alt_outlined, size: 18),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    state.targetName ?? 'Choose list',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
  );
}

final class _DateMenu extends StatelessWidget {
  const _DateMenu({required this.state, required this.onSelected});

  final QuickAddState state;
  final ValueChanged<DateShortcut> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<DateShortcut>(
    key: const Key('quick-add-date'),
    enabled: !state.isSubmitting,
    tooltip: 'Due date',
    onSelected: onSelected,
    itemBuilder: (context) => const <PopupMenuEntry<DateShortcut>>[
      PopupMenuItem(value: DateShortcut.today, child: Text('Due today')),
      PopupMenuItem(value: DateShortcut.tomorrow, child: Text('Due tomorrow')),
      PopupMenuItem(value: DateShortcut.nextWeek, child: Text('Due next week')),
      PopupMenuItem(
        value: DateShortcut.nextMonth,
        child: Text('Due next month'),
      ),
      PopupMenuDivider(),
      PopupMenuItem(value: DateShortcut.clear, child: Text('No due date')),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.event_outlined, size: 18),
          const SizedBox(width: 4),
          Text(state.previewDue == null ? 'Date' : 'Due ${state.previewDue}'),
        ],
      ),
    ),
  );
}

/// The phone's on-demand capture surface, opened by the floating add button
/// and pinned at the top of the task collection.
///
/// It drives the same [QuickAddViewModel] as the desktop [QuickAddBar], so
/// date parsing, destination, validation and persistence are shared; the
/// phone adds optional multiline notes. Cancel and submit sit on the title
/// row, which never scrolls: when the keyboard or a landscape screen leaves
/// little height, the notes and options below it scroll instead, so both
/// actions stay reachable above the keyboard.
final class PhoneComposerPanel extends StatefulWidget {
  const PhoneComposerPanel({
    required this.viewModel,
    required this.lists,
    required this.focusNode,
    required this.onCancel,
    this.onPasteMultiple,
    super.key,
  });

  final QuickAddViewModel viewModel;
  final List<CachedTaskList> lists;

  /// Focus of the title field; the shell requests it when the panel opens.
  final FocusNode focusNode;

  /// Discards the draft and closes the panel. Never creates a task.
  final VoidCallback onCancel;
  final VoidCallback? onPasteMultiple;

  @override
  State<PhoneComposerPanel> createState() => _PhoneComposerPanelState();
}

final class _PhoneComposerPanelState extends State<PhoneComposerPanel> {
  late final TextEditingController _title = TextEditingController();
  late final TextEditingController _notes = TextEditingController();
  final FocusNode _notesFocus = FocusNode(debugLabel: 'Composer notes');
  String? _focusRestoredFor;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _sync(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _submit() {
    if (widget.viewModel.state.isSubmitting) return;
    unawaited(widget.viewModel.submit());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) {
      final state = widget.viewModel.state;
      final colors = Theme.of(context).colorScheme;
      final completion = state.successMessage ?? state.failureMessage;
      final focusRestoreKey = completion == null
          ? null
          : '$completion:${state.input}:${state.notes}';
      if (focusRestoreKey != null && _focusRestoredFor != focusRestoreKey) {
        _focusRestoredFor = focusRestoreKey;
        // Rapid entry: after an add or a rejected add, keep composing in
        // the title unless the user is still writing notes.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_notesFocus.hasFocus) {
            widget.focusNode.requestFocus();
          }
        });
      }
      _sync(_title, state.input);
      _sync(_notes, state.notes);
      final canSubmit = !state.isSubmitting && state.targetId != null;
      final titleRow = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          IconButton(
            key: const Key('composer-cancel'),
            tooltip: 'Cancel',
            onPressed: state.isSubmitting ? null : widget.onCancel,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              key: const Key('quick-add-input'),
              controller: _title,
              focusNode: widget.focusNode,
              maxLength: 1024,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              // A hint rather than a floating label keeps the title row one
              // control high above a landscape keyboard.
              decoration: const InputDecoration(
                hintText: 'Task title',
                semanticCounterText: '',
                counterText: '',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(),
              ),
              onChanged: widget.viewModel.setInput,
              // Keep the field focused (and the keyboard up) for the next
              // capture; the view model clears it after a durable add.
              onEditingComplete: () {},
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const Key('quick-add-submit'),
            tooltip: 'Add task',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: canSubmit ? _submit : null,
            icon: state.isSubmitting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_upward),
          ),
        ],
      );
      final details = <Widget>[
        _CaptureFeedback(state: state, gap: 4),
        const SizedBox(height: 8),
        TextField(
          key: const Key('quick-add-notes'),
          controller: _notes,
          focusNode: _notesFocus,
          maxLength: 8192,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Notes (optional)',
            counterText: '',
            prefixIcon: Icon(Icons.notes_outlined),
            border: OutlineInputBorder(),
          ),
          onChanged: widget.viewModel.setNotes,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _DestinationMenu(
              compact: false,
              state: state,
              lists: widget.lists,
              onSelected: widget.viewModel.selectTarget,
            ),
            _DateMenu(
              state: state,
              onSelected: widget.viewModel.selectDueShortcut,
            ),
            if (widget.onPasteMultiple case final onPaste?)
              TextButton.icon(
                key: const Key('quick-add-paste-multiple'),
                onPressed: state.isSubmitting ? null : onPaste,
                icon: const Icon(Icons.content_paste_outlined, size: 18),
                label: const Text('Paste multiple'),
              ),
          ],
        ),
        _CapturePreview(
          state: state,
          gap: 0,
          onDismissParsedDate: widget.viewModel.dismissDatePreview,
        ),
      ];
      return Material(
        key: const Key('composer-surface'),
        color: colors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // Keyboard/rotation transitions can leave less than one
                  // scaled row of space. Bound its viewport, while keeping the
                  // same field element and input connection across rotations.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight,
                    ),
                    child: SingleChildScrollView(
                      key: const Key('composer-title-scroll'),
                      primary: false,
                      child: titleRow,
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      key: const Key('composer-details-scroll'),
                      primary: false,
                      padding: const EdgeInsets.only(left: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: details,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
