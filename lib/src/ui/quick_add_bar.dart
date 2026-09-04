// The quick-add composer's INPUT ROW (#274, split out of the orchestrator): the
// text field, its live natural-language date preview, the multi-line-paste
// split offer, the shared quick-date button, the destination picker, and
// submit.
//
// The same widget renders on BOTH composer surfaces — the desktop's
// always-visible bar and the phone's bottom-sheet composer — so drafts, date
// preview, landing toasts and the background flush behave identically on either
// pointer class. It is a pure renderer of the aim: the controller above it owns
// the draft, performs the create, and hands the row down through
// [QuickAddBarCallbacks].
//
// A keystroke rebuilds ONLY this bar (to update the preview) — never the
// enclosing list, so typing never re-runs the view's row derivation (F20 #199).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../app/quick_add.dart';
import '../model/dates.dart' show DateMove;
import '../store/stored.dart';
import 'bulk_add.dart';
import 'date_format.dart';
import 'quick_date_menu.dart';
import 'theme.dart';

/// The width the composer's input keeps for itself before the date preview may
/// claim any of the row (#223). The field spends ~32dp of it on its own border
/// and padding, so ~128dp of caret line survives — a readable draft while the
/// title is still being typed, rather than the four characters a full-width
/// chip used to leave on a 400dp phone.
const double _kDraftFloor = 160;

/// The always-visible quick-add input, its live date preview chip, and submit.
///
/// A keystroke rebuilds ONLY this bar (to update the natural-language date
/// preview) — never the enclosing [TaskListView], so typing never re-runs
/// `visibleTasksForView` or the per-row effective-due/subtask-count sweep (F20
/// #199). The bar therefore owns the preview computation locally; the parent
/// keeps the draft's aim (mirrored in via [dateIgnoredFor] and [pickedDue])
/// because its submit path still needs it, and re-reads the live controller text
/// at submit time. Those two come straight off the one [ComposerDraft] both
/// composer surfaces observe (#264), so the bar is a renderer of the aim and
/// never a second copy of it.
class QuickAddBar extends StatefulWidget {
  const QuickAddBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.dateIgnoredFor,
    required this.pickedDue,
    required this.lists,
    required this.targetListId,
    required this.onTargetChanged,
    required this.onSubmit,
    required this.onAddPastedLines,
    required this.onDismissPreview,
    required this.onSetDue,
    required this.onPickDue,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Every known list — the destinations the target picker offers (#217).
  final List<StoredTaskList> lists;

  /// The list the next add will land in (the user's pick, or the view's
  /// default). Owned by the parent, which also performs the create.
  final String? targetListId;

  /// Aim the composer at another list.
  final ValueChanged<String> onTargetChanged;

  /// The exact input text whose parsed date the user chose to keep as literal
  /// title text (the preview chip's ×), so its phrase is not re-read as a due
  /// date. Owned by the parent; changing it flows a fresh value down here.
  final String dateIgnoredFor;

  /// The date the user set EXPLICITLY on this draft from the date button
  /// (#243), or `null`. It outranks the parsed phrase, so the chip shows it and
  /// the create uses it. Owned by the parent (it performs the create).
  final String? pickedDue;

  /// Set the draft's date from the shared quick-date menu.
  final ValueChanged<DateMove> onSetDue;

  /// Open the calendar for the draft ("Pick a date…").
  final VoidCallback onPickDue;

  final VoidCallback onSubmit;

  /// Accept the multi-line-paste offer (#219): create one task per line of the
  /// RAW pasted text. The parent owns the create (and clears the draft).
  final ValueChanged<String> onAddPastedLines;
  final VoidCallback onDismissPreview;

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  /// The RAW multi-line text the last paste put into an empty composer, while
  /// the offer to split it into one task per line still stands (#219); `null`
  /// when nothing is on offer.
  String? _pasteOffer;

  /// The exact draft the standing offer belongs to. Editing away from it
  /// retracts the offer — "Add as N tasks" must never describe lines the field
  /// no longer shows.
  String _offerDraft = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_retractStaleOffer);
  }

  @override
  void dispose() {
    // The controller is the parent's; only the listener is ours.
    widget.controller.removeListener(_retractStaleOffer);
    super.dispose();
  }

  /// Retract a standing paste offer as soon as the draft is no longer the text
  /// that paste produced — a keystroke, or the parent clearing the field after
  /// a submit. "Add as N tasks" must never outlive the lines it describes.
  void _retractStaleOffer() {
    if (_pasteOffer == null || widget.controller.text == _offerDraft) return;
    setState(() => _pasteOffer = null);
  }

  /// Handle a paste ourselves (#219). A single-line [TextField] runs
  /// [FilteringTextInputFormatter.singleLineFormatter] BEFORE any formatter we
  /// could add, which DELETES the newlines ("buy milk\ncall bob" →
  /// "buy milkcall bob") and destroys the line structure before anything can
  /// read it. Intercepting the paste itself — the Ctrl+V intent and the
  /// selection toolbar's Paste, the two ways text arrives from the clipboard —
  /// is what keeps the raw text intact.
  ///
  /// It reads the clipboard exactly ONCE per paste (replacing, not adding to,
  /// the framework's own read), inserts the space-collapsed text at the caret,
  /// and raises the split offer when a list landed in an empty composer.
  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text ?? '';
    if (raw.isEmpty || !mounted) return;
    final draft = widget.controller.text;
    final insert = collapsePastedLines(raw);
    final selection = widget.controller.selection;
    final valid = selection.isValid && selection.start >= 0;
    final start = valid ? selection.start : draft.length;
    final end = valid ? selection.end : draft.length;
    final text = draft.replaceRange(start, end, insert);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {
      // What SURVIVES the paste decides: a list pasted over an empty field (or
      // over a select-all) is a list; lines spliced into a half-typed title are
      // part of that title.
      final remainder = draft.replaceRange(start, end, '');
      _pasteOffer = offersBulkSplit(draft: remainder, raw: raw) ? raw : null;
      _offerDraft = text;
    });
  }

  /// Retract the offer (the × / "Keep as one task"): the collapsed draft stays
  /// exactly as it is, an ordinary single-task draft.
  void _dismissOffer() => setState(() => _pasteOffer = null);

  /// The offer's label — width-capped so an accessibility text scale ellipsises
  /// it rather than overflowing the phone's single composer line.
  Widget _pasteOfferLabel(int count) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 120),
    child: Text(
      'Add as $count tasks',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  /// The selection toolbar with its Paste button rerouted through
  /// [_handlePaste] (#219) — the only clipboard route a finger has, and the one
  /// the phone's bottom-sheet composer uses. Every other button is the
  /// platform's own.
  Widget _pasteAwareContextMenu(
    BuildContext context,
    EditableTextState editableState,
  ) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableState.contextMenuAnchors,
    buttonItems: [
      for (final item in editableState.contextMenuButtonItems)
        if (item.type == ContextMenuButtonType.paste)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () {
              editableState.hideToolbar();
              _handlePaste();
            },
          )
        else
          item,
    ],
  );

  /// The natural-language due parsed from the CURRENT input, unless the user
  /// dismissed it for this exact text. Recomputed on each local rebuild so a
  /// keystroke updates only this bar. Mirrors [ComposerController.previewDue],
  /// which the parent's submit path reads from the same live controller text.
  String? get _previewDue =>
      widget.pickedDue ??
      (widget.controller.text == widget.dateIgnoredFor
          ? null
          : parseQuickAddDue(widget.controller.text));

  @override
  Widget build(BuildContext context) {
    final offer = _pasteOffer;
    final offerCount = offer == null ? 0 : splitBulkLines(offer).length;
    final preview = _previewDue;
    // One decision at a time: while the split is on offer the question is "one
    // task or N?", so the date chip stands down (it would also fight the offer
    // for the phone's single line). Declining brings it straight back — and the
    // per-line split parses each line's own date anyway.
    final hasPreview = offer == null && preview != null && preview.isNotEmpty;
    final touch = coarsePointerPlatform(Theme.of(context).platform);
    // A destination picker only earns its slot when there IS a choice: with one
    // list the default is the only answer, and dead chrome is not a feature.
    final picker = widget.lists.length > 1 && widget.targetListId != null
        ? _TargetListButton(
            lists: widget.lists,
            targetListId: widget.targetListId!,
            onChanged: widget.onTargetChanged,
            // A coarse pointer's composer line now permanently carries the
            // date button as well (#243), so on a phone there is no width left
            // for a labelled destination at any time — with a chip up or not.
            // The composer sheds the destination LABEL there, never the
            // control, whose menu still shows which list is checked (#217).
            compact: touch,
          )
        : null;
    return Padding(
      key: const Key('quick-add-bar'),
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The draft outranks the preview (#223): what is left of the row
          // once the input keeps its readable floor is ALL the date chip may
          // spend. A long label or an accessibility text scale ellipsises the
          // chip instead of squeezing the title being typed down to four
          // characters. The upper bound is #217's 120dp label cap plus the
          // chrome and × the chip now carries itself — a wide screen does not
          // make a date preview worth more of the row than that.
          final chipMax =
              (constraints.maxWidth -
                      _kDraftFloor -
                      8 - // the gap before the chip
                      // Whatever sits in the destination's slot: the picker
                      // (with its gap), or the decorative "+" the field falls
                      // back to — both cost the caret line the same 48dp.
                      (picker != null ? 52 : 48) -
                      52 - // gap + the date button (#243)
                      56 // gap + the send button
                      )
                  // The draft's floor OUTRANKS the chip: on a 400dp phone the
                  // row cannot seat a readable input, a date button, a
                  // destination and a send button AND a full-width chip, so
                  // the chip is what ellipsises (#223's ruling, re-applied now
                  // that the date button shares the line).
                  .clamp(48.0, 168.0);
          return Row(
            children: [
              Expanded(
                // Both clipboard routes are rerouted through [_handlePaste] (#219):
                // the keyboard's paste intent here (EditableText's own paste action
                // is overridable from an ancestor), and the selection toolbar's
                // Paste below. Nothing else about the field's editing changes.
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    PasteTextIntent: CallbackAction<PasteTextIntent>(
                      onInvoke: (_) {
                        _handlePaste();
                        return null;
                      },
                    ),
                  },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    decoration: InputDecoration(
                      hintText: 'Add a task',
                      // The decorative "+" yields its 48dp to the destination
                      // picker (#217) when there is one: the picker carries its own
                      // icon and sits on the same line, so the composer says "add"
                      // once and the input keeps exactly the room it had. With a
                      // single list there is nothing to pick and the "+" stays.
                      prefixIcon: picker == null ? const Icon(Icons.add) : null,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    contextMenuBuilder: _pasteAwareContextMenu,
                    // Rebuild THIS bar only, to refresh the date preview — the task
                    // list is untouched by a keystroke (F20 #199).
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => widget.onSubmit(),
                  ),
                ),
              ),
              if (offer != null) ...[
                const SizedBox(width: 8),
                // The offer itself (#219). Same idiom — and same footprint — as the
                // date chip it stands in for: an action plus a dismiss, so the
                // composer never grows a second line. The label is width-capped so
                // an accessibility text scale ellipsises it instead of overflowing
                // the phone row.
                if (touch) ...[
                  // ELEVATED, unlike the date chip in the same slot: this one
                  // carries no glyph of its own, and a filled, raised surface is
                  // what says "pressable" without one (an outlined chip beside
                  // an outlined field reads as a label; the date chip earns its
                  // press from the × it draws). No width is spent on a leading
                  // icon — the phone row has none to spare.
                  ActionChip.elevated(
                    key: const Key('quick-add-paste-split'),
                    label: _pasteOfferLabel(offerCount),
                    onPressed: () => widget.onAddPastedLines(offer),
                  ),
                  IconButton(
                    key: const Key('quick-add-paste-split-dismiss'),
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Keep as one task',
                    onPressed: _dismissOffer,
                  ),
                ] else
                  // The mouse keeps the compact inline form: a hover highlight and
                  // a pointer cursor already say "pressable", so no elevation is
                  // needed to earn the row's width back.
                  InputChip(
                    key: const Key('quick-add-paste-split'),
                    label: _pasteOfferLabel(offerCount),
                    onPressed: () => widget.onAddPastedLines(offer),
                    deleteIcon: const Icon(
                      Icons.close,
                      size: 18,
                      key: Key('quick-add-paste-split-dismiss'),
                    ),
                    deleteButtonTooltipMessage: 'Keep as one task',
                    onDeleted: _dismissOffer,
                  ),
              ],
              if (hasPreview) ...[
                const SizedBox(width: 8),
                // The chip renders a FRIENDLY relative date, never the raw ISO
                // (#78b); its × keeps the phrase as literal title text. On a
                // touch pointer the InputChip's built-in delete glyph is a
                // sub-48dp target, so the WHOLE chip carries the dismiss and is
                // finger-sized (F19 #198, #223); the mouse, with its precise
                // pointer and hover highlight, keeps the compact inline
                // InputChip whose small × it can hit.
                if (touch) ...[
                  // ONE child, not two (#223): the chip IS the "keep as text"
                  // button, so the finger-sized chip itself drops the date and
                  // the row is spared a standalone 48dp × beside it. The × is
                  // still drawn inside the chip — it is what says the chip is a
                  // way out rather than a label. [chipMax] is the row's
                  // leftover once the draft has its floor, so a long label (or
                  // an accessibility text scale) ellipsises the chip instead of
                  // squeezing the input.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: chipMax),
                    child: ActionChip(
                      key: const Key('quick-add-date-dismiss'),
                      tooltip: 'Keep as text',
                      // The chip's own 8dp padding is the only breathing room
                      // it needs; doubling it up with a label inset would cost
                      // the label glyphs the room instead.
                      labelPadding: EdgeInsets.zero,
                      onPressed: widget.onDismissPreview,
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              formatDue(preview),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.close, size: 18),
                        ],
                      ),
                    ),
                  ),
                ] else
                  InputChip(
                    label: Text(formatDue(preview)),
                    deleteIcon: const Icon(Icons.close, size: 18),
                    deleteButtonTooltipMessage: 'Keep as text',
                    onDeleted: widget.onDismissPreview,
                  ),
              ],
              // One tap to a date at CREATION (#243): the same frozen option
              // set every other surface offers, so a task can be born dated
              // without typing a phrase or opening the detail panel. With a
              // date already on the draft it stays on the row — it is how that
              // date is CHANGED (the chip's × only removes it).
              //
              // It stands down for the paste-split offer, exactly as the date
              // chip does: while the question is "one task or N?" a date is
              // not the decision being made, and the offer needs the width.
              if (offer == null) ...[
                const SizedBox(width: 4),
                QuickDateAnchor(
                  onSetDue: widget.onSetDue,
                  onPickDate: widget.onPickDue,
                  sheetTitle: 'Due date for this task',
                  builder: (context, open) => IconButton(
                    key: const Key('quick-add-date-button'),
                    tooltip: 'Set a due date',
                    // A finger-sized target on the composer's single line.
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: const Icon(Icons.event_outlined),
                    onPressed: open,
                  ),
                ),
              ],
              // The destination sits between the draft and the send button, so the
              // row reads "<title> → <list> ↑" (#217).
              if (picker != null) ...[const SizedBox(width: 4), picker],
              const SizedBox(width: 8),
              IconButton.filled(
                key: const Key('quick-add-submit'),
                tooltip: 'Add task',
                icon: const Icon(Icons.arrow_upward),
                onPressed: widget.onSubmit,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The quick-add's target-list picker (#217) — a compact anchored menu naming
/// where the next add lands, and retargeting it in one tap WITHOUT costing the
/// composer a second line (the ratified mobile constraint).
///
/// The pick is transient by design: it survives consecutive adds but is never
/// written to prefs and resets when the view changes, so the composer's aim is
/// always either "here" or something the user set moments ago.
class _TargetListButton extends StatelessWidget {
  const _TargetListButton({
    required this.lists,
    required this.targetListId,
    required this.onChanged,
    required this.compact,
  });

  final List<StoredTaskList> lists;

  /// The list the next add lands in — checked in the menu, named on the button.
  final String targetListId;
  final ValueChanged<String> onChanged;

  /// Drop the label and show the icon alone (a crowded phone row).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = lists
        .firstWhere((l) => l.list.id == targetListId, orElse: () => lists.first)
        .list
        .title;
    // The menu never claims more height than the screen leaves once the soft
    // keyboard is up — the composer is ALWAYS typed into, so an uncapped menu
    // over a long list of lists puts its last entries behind the IME where no
    // finger can reach them. Capped, it scrolls instead.
    final media = MediaQuery.of(context);
    final maxMenuHeight = media.size.height - media.viewInsets.bottom - 64;
    return MenuAnchor(
      style: MenuStyle(
        maximumSize: WidgetStatePropertyAll(
          Size.fromHeight(maxMenuHeight.clamp(96.0, double.infinity)),
        ),
      ),
      menuChildren: [
        for (final l in lists)
          MenuItemButton(
            key: Key('quick-add-list-${l.list.id}'),
            leadingIcon: l.list.id == targetListId
                ? const Icon(Icons.check, size: 18)
                : const SizedBox(width: 18),
            onPressed: () => onChanged(l.list.id),
            child: Text(l.list.title),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        // The compact form is icon-only, so the destination has to be readable
        // some other way: hover on the desktop, long-press on a phone, and the
        // screen-reader label either way.
        message: 'Add to list: $title',
        child: ConstrainedBox(
          // The label truncates rather than pushing the input out of the row.
          constraints: BoxConstraints(maxWidth: compact ? 48 : 132),
          child: TextButton(
            key: const Key('quick-add-list-picker'),
            style: TextButton.styleFrom(
              // A finger-sized target on the composer's single line.
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.playlist_add, size: 20),
                if (!compact) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
