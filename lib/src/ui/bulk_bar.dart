// The multi-select bulk bar (BulkOps). Shown while selection MODE is active;
// carries the whole-selection actions — Complete, "Due" (the ONE shared
// quick-date menu, #243), Move to a list, Delete, and behind a "⋮" the two
// rarer ones, Duplicate and "Make subtasks of…" — plus a clear-selection
// button. Each op is the caller's to perform against the selected ids; this
// widget only renders the toolbar and reports the count.
//
// Duplicate and "Make subtasks of…" landed here with #245, when the per-row "⋮"
// sheet — their only touch home — was retired. The bar can also be raised with
// NOTHING selected (the toolbar's "Select tasks"): it then names the mode and
// every whole-selection action is disabled, because a button that would do
// nothing is worse than no button.
//
// The four hard-coded date buttons this replaced (Today / Tomorrow / Next week
// / Clear date) were a fourth vocabulary AND a subset — bulk could not reach
// "Next month" or a picked day at all. Behind one "Due" button the whole frozen
// set is available to a selection, exactly as it is to a single row.
//
// ── ONE ROW (#265) ─────────────────────────────────────────────────────────
// Those two changes left seven spelled-out buttons in a [Wrap], and on the
// device the app is FOR that is not a toolbar: at 400dp the labels flowed onto
// FOUR runs — 264dp of permanent chrome above the first row, on top of the app
// bar and the bottom nav — and 340dp at the 2.0 accessibility text scale. A bar
// whose height is a function of how long its labels happen to be will always
// find a width where it eats the list.
//
// So the bar is ONE row, [BulkBar.height] tall, at every width and every text
// scale. What adapts is the LABELS, not the geometry: the row is measured
// against the space it actually has ([_labelsFit]) and spells its actions out
// when they fit, or falls back to icons with tooltips when they do not. The
// decision is a FIT, never a breakpoint — a 700dp pane at 2.0x text has no more
// room than a phone does at 1.0x, so a rule written in widths would wrap on
// exactly the surface a wrap hurts most.
//
// Only four actions are ever on the row. Duplicate and "Make subtasks of…" are
// the two a selection reaches least often, and a menu entry costs one extra
// tap; four everyday actions that never move are worth more than six that
// reflow.
//
// The bar stays ABOVE the list — it is the list pane's own chrome, never a
// morph of the shell's app bar: the view's title, its hamburger and its scroll
// behaviour are not the selection's to take over, and a bar that replaces
// another bar leaves the user nothing on screen that did not just change.
//
// The `x`-key / Space / Ctrl+M keyboard triggers of the reference die with the
// keyboard layer; every action here is a tappable button, so touch and mouse
// reach them alike.

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;
import 'motion.dart';
import 'quick_date_menu.dart';

/// The bar's own end padding.
const double _kEdge = 4;

/// A square icon-button slot (Material's 48dp minimum tap target).
const double _kSquare = 48;

/// The gap the count text keeps from the actions after it.
const double _kCountGap = 12;

/// Everything a SPELLED-OUT action button spends besides its label: 12dp of
/// padding on each side, an 18dp leading icon, and the 8dp gap after it. Kept
/// in step with [_spelledStyle] and BulkBar._action — [BulkBar._labelsFit]
/// measures the row with these numbers, so a change to one is a change to all
/// three.
const double _kSpelledChrome = 12 + 12 + 18 + 8;

/// The extra width "Due ▾" spends on its caret.
const double _kCaret = 18;

/// The stand-in the fit is measured against instead of the count phrase itself.
///
/// The room the count needs must NOT depend on the count, or the row changes
/// FORM as a selection grows: at a width where "9 selected" fits spelled out
/// and "10 selected" does not, picking one more row would drop all four labels
/// to icons under the finger. So the reserve is a fixed worst case — three
/// digits and the longest word the bar ever puts beside them — and it is the
/// COUNT that gives way inside it, never the layout.
const String _kCountReserve = '000 selected';

/// The style of a spelled-out action: fixed padding (so the fit arithmetic is
/// something the button will actually honour) and a 48dp minimum tap target
/// that still fits inside [BulkBar.height].
final ButtonStyle _spelledStyle = TextButton.styleFrom(
  padding: const EdgeInsets.symmetric(horizontal: 12),
  minimumSize: const Size(_kSquare, _kSquare),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// The bulk-actions toolbar for [count] selected tasks.
class BulkBar extends StatelessWidget {
  const BulkBar({
    required this.count,
    required this.onComplete,
    required this.onSetDue,
    required this.onPickDue,
    required this.onMove,
    required this.onDuplicate,
    required this.onDemote,
    required this.onDelete,
    required this.onClear,
    super.key,
  });

  /// The bar is ONE row this tall — at every width, and at every text scale.
  /// The list below it therefore never moves when the labels do.
  static const double height = 56;

  /// How many tasks are selected. Zero is legal — the mode was entered from the
  /// toolbar and no row has been tapped yet.
  final int count;

  final VoidCallback onComplete;

  /// Apply a frozen move to every selected task.
  final void Function(DateMove move) onSetDue;

  /// Open the calendar ("Pick a date…") and apply the chosen day to every
  /// selected task.
  final VoidCallback onPickDue;

  final VoidCallback onMove;

  /// Copy every selected task ("`<title>` (copy)", same list, same parent).
  final VoidCallback onDuplicate;

  /// Nest every selected task under ONE parent picked from the #88 picker.
  /// `null` HIDES the action — no single task can host the whole selection
  /// (one of them has subtasks of its own, or the selection spans lists), and
  /// the two-level invariant is not negotiable.
  final VoidCallback? onDemote;

  final VoidCallback onDelete;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Nothing selected yet: the actions are inert, so they READ inert — and
    // the destructive tint belongs to a LIVE Delete, never a disabled one.
    final armed = count > 0;
    final danger = armed ? theme.colorScheme.error : theme.disabledColor;
    final countLabel = armed ? '$count selected' : 'Select tasks';
    final countStyle = theme.textTheme.labelLarge;

    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final spelled = _labelsFit(
              context,
              countStyle: countStyle,
              width: constraints.maxWidth,
            );
            // Even the icon row can run out of room for the whole phrase at a
            // large text scale. The NUMBER is the information — "3 sel…" spends
            // the same space to say less — so the phrase degrades to the count
            // itself, and goes on being read out in full.
            final countText =
                spelled ||
                    _countFits(
                      context,
                      countLabel,
                      countStyle,
                      constraints.maxWidth,
                    )
                ? countLabel
                : '$count';
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: _kEdge),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('bulk-clear-selection'),
                    tooltip: 'Clear selection',
                    icon: const Icon(Icons.close),
                    onPressed: onClear,
                  ),
                  // Takes the slack, so the actions sit at the far end however
                  // wide the surface is — and ellipsises rather than pushing an
                  // action off the row when there is none to take.
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: _kCountGap),
                      child: Semantics(
                        label: countLabel,
                        child: ExcludeSemantics(
                          child: Text(
                            countText,
                            key: const Key('bulk-count'),
                            style: countStyle,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _action(
                    id: 'bulk-complete',
                    icon: Icons.check,
                    label: 'Complete',
                    onPressed: armed ? onComplete : null,
                    spelled: spelled,
                  ),
                  QuickDateAnchor(
                    onSetDue: onSetDue,
                    onPickDate: onPickDue,
                    sheetTitle: '$count selected · due date',
                    builder: (context, open) => _action(
                      id: 'bulk-due',
                      icon: Icons.event,
                      label: 'Due',
                      onPressed: armed ? open : null,
                      spelled: spelled,
                      // The caret says "this opens the shared quick-date set"
                      // where there is room to say it; the icon-only form leans
                      // on the tooltip instead of hanging a second glyph off a
                      // 24dp icon.
                      trailing: const Icon(Icons.arrow_drop_down, size: 18),
                    ),
                  ),
                  _action(
                    id: 'bulk-move',
                    icon: Icons.drive_file_move_outline,
                    label: 'Move',
                    onPressed: armed ? onMove : null,
                    spelled: spelled,
                  ),
                  _action(
                    id: 'bulk-delete',
                    icon: Icons.delete_outline,
                    label: 'Delete',
                    onPressed: armed ? onDelete : null,
                    spelled: spelled,
                    color: danger,
                  ),
                  // The two rarer ops. Disabled outright with nothing selected:
                  // a "⋮" that opens a menu of dead entries is worse than one
                  // that plainly cannot be pressed.
                  PopupMenuButton<String>(
                    key: const Key('bulk-overflow'),
                    tooltip: 'More bulk actions',
                    icon: const Icon(Icons.more_vert),
                    enabled: armed,
                    // The bar sits INSIDE the shell's nested navigator, and a
                    // surface raised from there is a route the OS's back never
                    // reaches — it would fall through to the shell's ladder and
                    // clear the selection with the menu still standing (#234's
                    // rule, same reason the quick-date sheet takes the root).
                    useRootNavigator: true,
                    onSelected: (id) =>
                        id == 'duplicate' ? onDuplicate() : onDemote!(),
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        key: const Key('bulk-duplicate'),
                        value: 'duplicate',
                        child: _overflowEntry(
                          Icons.copy_all_outlined,
                          'Duplicate',
                        ),
                      ),
                      if (onDemote != null)
                        PopupMenuItem<String>(
                          key: const Key('bulk-demote'),
                          value: 'demote',
                          child: _overflowEntry(
                            Icons.subdirectory_arrow_right,
                            'Make subtasks of…',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// One whole-selection action: spelled out when the row has the width for it,
  /// an icon with the same word as its tooltip when it does not. Same key, same
  /// order and the same tap target either way, so a test — and a finger — finds
  /// it in the same place.
  Widget _action({
    required String id,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required bool spelled,
    Color? color,
    Widget? trailing,
  }) {
    if (!spelled) {
      return IconButton(
        key: Key(id),
        tooltip: label,
        icon: Icon(icon, color: color),
        onPressed: onPressed,
      );
    }
    return TextButton(
      key: Key(id),
      style: _spelledStyle,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: color == null ? null : TextStyle(color: color),
          ),
          ?trailing,
        ],
      ),
    );
  }

  /// A "⋮" entry. The label is [Flexible] because a Material menu caps its
  /// width: at a large text scale it wraps rather than being clipped.
  Widget _overflowEntry(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );

  /// Does the SPELLED-OUT row fit in [width]?
  ///
  /// Measured, not guessed at a breakpoint: the labels are laid out with the
  /// context's own text scaler, and everything else on the row is a constant
  /// this file also imposes ([_kSpelledChrome], [_spelledStyle]).
  bool _labelsFit(
    BuildContext context, {
    required TextStyle? countStyle,
    required double width,
  }) {
    if (!width.isFinite) return true;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double measure(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final result = painter.width;
      painter.dispose();
      return result;
    }

    // The × and the ⋮ are square whatever happens; the count text and the four
    // labels are what grow.
    var needed =
        _kEdge * 2 +
        _kSquare * 2 +
        _kCountGap +
        _kCaret +
        measure(_kCountReserve, countStyle);
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    for (final label in const ['Complete', 'Due', 'Move', 'Delete']) {
      needed += _kSpelledChrome + measure(label, labelStyle);
    }
    return needed <= width;
  }

  /// Does the whole count PHRASE fit beside the icon row — the × , the four
  /// actions and the ⋮, all of them square whatever the text scale is?
  bool _countFits(
    BuildContext context,
    String countLabel,
    TextStyle? countStyle,
    double width,
  ) {
    if (!width.isFinite) return true;
    final painter = TextPainter(
      text: TextSpan(text: countLabel, style: countStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final needed = painter.width;
    painter.dispose();
    return needed <= width - (_kEdge * 2 + _kSquare * 6 + _kCountGap);
  }
}

/// The slot the [BulkBar] occupies above the list: empty until a selection
/// starts, then the bar's own height.
///
/// The bar arrives and leaves by COLLAPSING that height over [Motion]'s medium
/// span — the rows below make room for it and close over it again, so a
/// selection never shoves the whole list a bar's worth in one frame. Under
/// reduced motion the span is zero and the end state is simply reached.
///
/// [builder] is called only while the bar is [shown]; the last bar it built is
/// what plays the exit, so a selection folding away does not first flicker to
/// "Select tasks" as the count it was showing drops to zero.
class BulkBarSlot extends StatefulWidget {
  const BulkBarSlot({required this.shown, required this.builder, super.key});

  /// Whether selection mode is on.
  final bool shown;

  /// Builds the bar. Called only while [shown].
  final WidgetBuilder builder;

  @override
  State<BulkBarSlot> createState() => _BulkBarSlotState();
}

class _BulkBarSlotState extends State<BulkBarSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.shown ? 1 : 0,
  );

  Widget? _last;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-read whenever the platform's reduced-motion setting can have changed;
    // the controller is then zero-span and jumps to its end state.
    _controller.duration = Motion.of(context).medium;
  }

  @override
  void didUpdateWidget(covariant BulkBarSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shown != oldWidget.shown) {
      if (widget.shown) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.shown) {
      _last = widget.builder(context);
    } else if (_controller.value == 0) {
      _last = null;
    }
    final bar = _last;
    if (bar == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // The direction comes from our OWN flag, never from the controller's
        // status: that status lags a tick, so a reverse begun on the frame an
        // enter finished would play the arriving curve backwards.
        final curve = widget.shown ? MotionCurves.enter : MotionCurves.exit;
        final factor = curve.transform(_controller.value);
        // Fully folded: the bar leaves the tree, rather than lingering as a
        // zero-height ghost that still answers a finder or a hit test.
        if (factor == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: factor,
            child: child,
          ),
        );
      },
      child: bar,
    );
  }
}
