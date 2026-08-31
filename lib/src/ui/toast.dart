// The toast / undo stack — the in-app feedback surface (T7.8).
//
// Two jobs: surface a failed command as a calm, auto-dismissing ERROR toast
// (the message is already redacted by `user_message.dart` before it gets here),
// and offer a reversible action as an UNDO toast whose button reverts it. The
// stack coexists: a sync-error toast raised while an undo toast is up must not
// evict the undo (the user must still be able to undo).
//
// The overlay mounts ABOVE the router's Navigator (via MaterialApp.builder), so
// a toast out-stacks every modal overlay — dialogs, the detail panel, pickers.
// That is invariant #11 made structural: feedback that a modal paints over
// protects nothing (#172). This is the ONE feedback surface (F19 #198): undo
// and info notices route here, never through ScaffoldMessenger — a SnackBar
// renders BELOW modal routes, so an undo raised from the detail panel or a
// dialog would be swallowed by the very surface it belongs to.
//
// Auto-dismiss runs on a per-toast [RestartableTimer] (package:async — the repo
// bans a raw dart:async `Timer` below lib/): cancellable, so a dismiss or a
// [ToastController.dispose] tears its timer down and no widget test ends with a
// pending 30-second undo timer.
//
// ── Motion (#258) ──────────────────────────────────────────────────────────
// Before this the surface had none: a card existed on one frame and not on the
// previous one, which at the far corner of a large window is feedback the eye
// never catches. So a card ARRIVES — up [kToastSlide] and fading in over
// [Motion.medium], decelerating — and LEAVES by exactly the reverse,
// accelerating away. Nothing here is a separate "replacement" animation: when
// one toast displaces another the two spans overlap on the same frames, and
// that overlap IS the cross-fade.
//
// Three things follow from a toast being a DEADLINE rather than a notice:
//
//   • an action toast draws a countdown along its bottom edge, so the 30-second
//     undo window is visible instead of ending as a surprise;
//   • a pointer resting on the card (hover on the desktop, a finger on the
//     phone) HOLDS that deadline — and holds the bar with it, so the pause is
//     something the user can see. Release restarts the full span, because the
//     [RestartableTimer] underneath counts from its original duration and the
//     bar must never claim more time than the timer will actually give;
//   • a coarse pointer can throw the card away downwards. Taking Undo and
//     getting rid of the toast are different intentions and the swipe is only
//     ever the second one.
//
// Past [kToastStackLimit] cards the stack stops growing and collapses to the
// NEWEST card with a "+N" pill. Collapsed toasts are HIDDEN, not dropped: they
// keep their own lives, and one that outlives the cards covering it comes back
// on its own — which is what keeps the #172 promise that an undo raised behind
// a wall of errors is still reachable.
//
// Reduced motion resolves the enter/exit spans to zero — a card is simply
// there, or simply gone — but it does NOT delete the countdown, which is
// information rather than decoration. The bar stops sweeping and steps once a
// second instead.
//
// One consequence for tests: while an action toast is up the countdown keeps
// scheduling frames for its whole life, so `pumpAndSettle` does not idle until
// the toast has LAPSED. A suite that raises one and then asserts on it must use
// a bounded pump (the convention this repo already follows for a focused
// TextField's cursor — see TESTING.md).

import 'package:async/async.dart' show RestartableTimer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'haptics.dart';
import 'motion.dart';
import 'theme.dart' show coarsePointerPlatform;

/// How a toast reads: a neutral [info]/undo notice, or a red [error].
enum ToastVariant { info, error }

/// How long an error toast lives before auto-dismissing.
const Duration kErrorToastDuration = Duration(seconds: 5);

/// How long a plain info toast lives.
const Duration kInfoToastDuration = Duration(seconds: 4);

/// How long an undo toast stays reachable before it lapses.
const Duration kUndoToastDuration = Duration(seconds: 30);

/// How far a toast travels as it arrives, and back as it leaves (#258). Far
/// enough that the card is read as coming FROM somewhere, short enough that it
/// never looks like it is being thrown.
const double kToastSlide = 16;

/// How many cards the stack shows before it collapses to the newest one plus a
/// "+N" pill (#258). Two is the most a corner of the screen can hold without
/// becoming a panel the user has to read rather than glance at.
const int kToastStackLimit = 2;

/// The countdown bar's thickness. A hairline reads as a rendering artefact; a
/// progress bar's 4dp reads as work in progress. Three is a deadline.
const double kToastCountdownThickness = 3;

/// The test handle on a toast's fade layer.
Key toastFadeKey(int id) => ValueKey<String>('toast-fade-$id');

/// The test handle on a toast's countdown bar.
Key toastCountdownKey(int id) => ValueKey<String>('toast-countdown-$id');

/// One entry in the stack. Immutable; the controller owns the list and timers.
class ToastData {
  const ToastData({
    required this.id,
    required this.message,
    required this.variant,
    this.onUndo,
    this.actionLabel,
    this.life,
  });

  /// A process-unique id (the stack key and the dismiss handle).
  final int id;

  /// The user-visible text (already redacted for errors).
  final String message;

  /// Info vs error styling.
  final ToastVariant variant;

  /// The action run by the toast's button; when non-null the toast shows a
  /// text button. It is the undo revert for an undo toast, or the jump for a
  /// landing toast (see [actionLabel]).
  final VoidCallback? onUndo;

  /// The button's label — defaults to "Undo" when null, so an undo toast needs
  /// no label. A landing/info toast passes its own ("View").
  final String? actionLabel;

  /// How long this toast was given, or null if it persists until dismissed.
  /// The card draws it as a countdown when there is something to act on.
  final Duration? life;

  /// Whether this toast is a DEADLINE the user can miss — it offers an action
  /// and it will lapse. Only those draw a countdown and hold it under a
  /// pointer: a bar on a card with nothing to act on measures nothing the user
  /// can do anything about, and a hold no bar explains is invisible behaviour.
  bool get hasCountdown => onUndo != null && life != null;
}

/// Owns the live toast list and each toast's auto-dismiss timer. A
/// [ChangeNotifier] so the [ToastStack] rebuilds on any change; not tied to a
/// widget, so a background sync or a command handler can raise a toast without
/// a [BuildContext].
class ToastController extends ChangeNotifier {
  final List<ToastData> _toasts = <ToastData>[];
  // The live auto-dismiss timers, keyed by toast id — cancelled on dismiss and
  // on dispose so nothing outlives its toast (or the controller).
  final Map<int, RestartableTimer> _timers = <int, RestartableTimer>{};
  int _seq = 0;
  bool _disposed = false;

  /// The live stack, oldest first.
  List<ToastData> get toasts => List<ToastData>.unmodifiable(_toasts);

  /// Show a toast; returns its id. [duration] `null` means it persists until
  /// dismissed (or reverted). [onUndo] wires the action button, [actionLabel]
  /// names it (defaults to "Undo").
  int show(
    String message, {
    ToastVariant variant = ToastVariant.info,
    VoidCallback? onUndo,
    String? actionLabel,
    Duration? duration,
  }) {
    final id = _seq++;
    _toasts.add(
      ToastData(
        id: id,
        message: message,
        variant: variant,
        onUndo: onUndo,
        actionLabel: actionLabel,
        life: duration,
      ),
    );
    if (duration != null) {
      // Auto-dismiss via a cancellable RestartableTimer (never a raw Timer —
      // banned below lib/ as an uncontrollable time source). Stored so dismiss
      // and dispose can cancel it: no widget test ends with a pending 30s undo
      // timer, and an already-dismissed toast's timer never fires late.
      _timers[id] = RestartableTimer(duration, () {
        if (!_disposed) dismiss(id);
      });
    }
    notifyListeners();
    return id;
  }

  /// Show a red error toast (5s life). An identical error that is still visible
  /// is NOT repeated — a background failure reporting the same message every
  /// cadence tick must not stack a wall of duplicates (#4 dedup).
  int showError(String message) {
    for (final t in _toasts) {
      if (t.variant == ToastVariant.error && t.message == message) return t.id;
    }
    return show(
      message,
      variant: ToastVariant.error,
      duration: kErrorToastDuration,
    );
  }

  /// Show an info toast (4s life).
  int showInfo(String message) => show(message, duration: kInfoToastDuration);

  /// Show an info toast with a single labelled action (e.g. a landing toast's
  /// "View" jump). Lives [duration] (default 6s — long enough to act on, short
  /// enough not to linger) if not acted on.
  int showAction(
    String message, {
    required String actionLabel,
    required VoidCallback onAction,
    Duration duration = const Duration(seconds: 6),
  }) {
    return show(
      message,
      onUndo: onAction,
      actionLabel: actionLabel,
      duration: duration,
    );
  }

  /// Show an undo toast: a message plus an Undo button that runs [onUndo] and
  /// then dismisses the toast. Lasts [duration] (default 30s) if not acted on.
  int showUndo(
    String message,
    VoidCallback onUndo, {
    Duration duration = kUndoToastDuration,
  }) {
    return show(message, onUndo: onUndo, duration: duration);
  }

  /// Hold toast [id]'s life while the user is on it (#258) — a no-op for a
  /// toast that has none. A card the pointer is resting on cannot lapse out
  /// from under the hand that is reaching for its button.
  void hold(int id) => _timers[id]?.cancel();

  /// Give toast [id] its FULL life back. The [RestartableTimer] underneath
  /// always counts from its original duration, so a released toast restarts
  /// rather than resuming — and the countdown bar refills to say so, because a
  /// bar that carried on from where it stopped would be claiming time the timer
  /// is not going to give.
  void release(int id) => _timers[id]?.reset();

  /// Remove toast [id] (a no-op if it is already gone) and cancel its pending
  /// auto-dismiss timer so it can never fire late.
  void dismiss(int id) {
    _timers.remove(id)?.cancel();
    final before = _toasts.length;
    _toasts.removeWhere((t) => t.id == id);
    if (_toasts.length != before && !_disposed) notifyListeners();
  }

  /// Run an undo toast's action, then dismiss it.
  void _undo(ToastData t) {
    t.onUndo?.call();
    dismiss(t.id);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _toasts.clear();
    super.dispose();
  }
}

/// Wraps [child] and paints the [ToastStack] above it. Used as
/// `MaterialApp.router`'s `builder`, so the stack sits above the whole
/// Navigator (routes AND modal overlays).
///
/// The stack lives in its OWN [Overlay] — a single static entry — so the cards
/// (which use tooltips) have an Overlay ancestor even though they render above
/// the app's Navigator, and so the layer above modals is real.
class ToastOverlay extends StatefulWidget {
  const ToastOverlay({
    required this.controller,
    required this.child,
    this.haptics = const NoHaptics(),
    super.key,
  });

  final ToastController controller;
  final Widget child;

  /// The haptic seam an Undo answers through (#257). Undo is the one toast
  /// action that reverses something the user already saw happen, so it is felt
  /// exactly as firmly as the delete it undoes. A labelled action ("View" on a
  /// landing toast) is navigation and stays silent.
  final Haptics haptics;

  @override
  State<ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<ToastOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) =>
        ToastStack(controller: widget.controller, haptics: widget.haptics),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned.fill(child: Overlay(initialEntries: <OverlayEntry>[_entry])),
      ],
    );
  }
}

/// Renders the controller's live stack, anchored to the bottom trailing corner.
/// Only the cards are hit-testable; the empty region passes pointers through to
/// the app beneath.
///
/// Stateful because a card outlives its toast: once the controller has dropped
/// an entry the card is still on screen playing its exit, so the stack renders
/// the union of what is SHOWN and what is still leaving.
class ToastStack extends StatefulWidget {
  const ToastStack({
    required this.controller,
    this.haptics = const NoHaptics(),
    super.key,
  });

  final ToastController controller;

  /// See [ToastOverlay.haptics].
  final Haptics haptics;

  @override
  State<ToastStack> createState() => _ToastStackState();
}

class _ToastStackState extends State<ToastStack> {
  /// Every card currently on screen — the shown ones plus any still leaving —
  /// keyed by id. Ids are handed out in order, so sorting the keys IS oldest
  /// first.
  final Map<int, ToastData> _cards = <int, ToastData>{};

  /// The toasts that get a card of their own right now: everything, until the
  /// stack passes [kToastStackLimit] and collapses to the newest.
  List<ToastData> get _shown {
    final live = widget.controller.toasts;
    if (live.length <= kToastStackLimit) return live;
    return <ToastData>[live.last];
  }

  /// Drop a card once its exit has played — unless the toast came BACK first
  /// (a collapsed one uncovered by the cards above it lapsing), in which case
  /// the card is arriving again and must stay.
  void _drop(int id) {
    if (!mounted || _shown.any((t) => t.id == id)) return;
    setState(() => _cards.remove(id));
  }

  /// A swipe IS the exit (#258): the card has already left under the finger, so
  /// it is taken out of the render set in the same frame rather than fading a
  /// second time. Undo is deliberately not taken — throwing the toast away and
  /// reversing the action are different intentions.
  void _swipedAway(int id) {
    setState(() => _cards.remove(id));
    widget.controller.dismiss(id);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final shown = _shown;
        // A LinkedHashSet — insertion-ordered, and [_shown] is oldest first, so
        // `lastOrNull` is the newest toast on screen.
        final shownIds = <int>{for (final t in shown) t.id};
        for (final t in shown) {
          _cards[t.id] = t;
        }
        if (_cards.isEmpty) return const SizedBox.shrink();
        final overflow = widget.controller.toasts.length - shown.length;
        final ids = _cards.keys.toList()..sort();
        final coarse = coarsePointerPlatform(Theme.of(context).platform);
        return SafeArea(
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    for (final id in ids)
                      _ToastMotion(
                        key: ValueKey<int>(id),
                        id: id,
                        shown: shownIds.contains(id),
                        onGone: () => _drop(id),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _card(
                            _cards[id]!,
                            // The pill belongs to the card the stack collapsed
                            // ONTO — the newest SHOWN toast. Never to a card
                            // that is only still here to play its exit: when
                            // the collapsed card is itself dismissed, the pill
                            // has to move to the one arriving behind it on the
                            // same frame, not ride the one leaving.
                            overflow: id == shownIds.lastOrNull ? overflow : 0,
                            coarse: coarse,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _card(ToastData t, {required int overflow, required bool coarse}) {
    final card = ToastCard(
      toast: t,
      overflow: overflow,
      onUndo: t.onUndo == null
          ? null
          : () {
              // An UNDO (the unlabelled button) is a reversal and is felt; a
              // labelled action is a jump and is not (#257).
              if (t.actionLabel == null) widget.haptics.confirm();
              widget.controller._undo(t);
            },
      onDismiss: () => widget.controller.dismiss(t.id),
      onHold: t.hasCountdown
          ? (held) => held
                ? widget.controller.hold(t.id)
                : widget.controller.release(t.id)
          : null,
    );
    if (!coarse) return card;
    // The coarse-pointer way out. Downward, matching the platform's own
    // SnackBar: the card sits against the trailing edge, where a horizontal
    // fling is the system back gesture's, and horizontal on a row already means
    // "act on this" everywhere else in the app.
    return Dismissible(
      key: ValueKey<String>('toast-dismissible-${t.id}'),
      direction: DismissDirection.down,
      // No resize phase: the slot goes with the card, in the same frame.
      resizeDuration: null,
      onDismissed: (_) => _swipedAway(t.id),
      child: card,
    );
  }
}

/// Plays one card's arrival and departure (#258).
///
/// At rest it is a pure pass-through — zero translation, opacity one — so a
/// settled stack paints and measures exactly as it did before there was any
/// motion at all.
class _ToastMotion extends StatefulWidget {
  const _ToastMotion({
    required this.id,
    required this.shown,
    required this.onGone,
    required this.child,
    super.key,
  });

  final int id;

  /// Whether this card belongs on screen. False means it is only still here to
  /// play its exit.
  final bool shown;

  /// Called once the exit has played and the card can be dropped.
  final VoidCallback onGone;

  final Widget child;

  @override
  State<_ToastMotion> createState() => _ToastMotionState();
}

class _ToastMotionState extends State<_ToastMotion>
    with SingleTickerProviderStateMixin {
  // Straight presence, 0 (not here) to 1 (fully placed). The EASING is applied
  // in the builder rather than by a [CurvedAnimation], because which curve
  // applies is decided by [_ToastMotion.shown] — the authoritative statement of
  // which way the card is going — and not by the controller's status, which
  // reports `completed` one tick after it reaches the end. A card dismissed on
  // the frame it finished arriving would otherwise leave along the ENTER curve.
  late final AnimationController _c = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than initState: the reduced-motion rule reads an inherited
    // widget. Under it the span is zero and the controller reaches its end in
    // the same frame — the card is simply there, or simply gone.
    _c.duration = Motion.of(context).medium;
    if (!_started) {
      _started = true;
      _c.addStatusListener(_onStatus);
      _play();
    }
  }

  @override
  void didUpdateWidget(covariant _ToastMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shown != oldWidget.shown) _play();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _play() {
    if (widget.shown) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || widget.shown) return;
    // After the frame: [onGone] rebuilds the stack, and a zero span reaches
    // this from inside a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onGone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final v = _c.value.clamp(0.0, 1.0);
        // Arriving, the curve runs with the motion: fast, then settling.
        // Leaving, it is applied to the DEPARTURE's own progress (the same way
        // a list row folds away, #251) so the card holds for a moment and then
        // accelerates out, rather than dropping most of the way in the first
        // few frames.
        final t = widget.shown
            ? MotionCurves.enter.transform(v)
            : 1 - MotionCurves.exit.transform(1 - v);
        // A finished exit paints nothing from the frame it finishes, rather
        // than one frame later when [onGone] has rebuilt the stack: a card that
        // lingered at zero opacity would still be holding its slot open.
        if (!widget.shown && t <= 0) return const SizedBox.shrink();
        return Transform.translate(
          offset: Offset(0, (1 - t) * kToastSlide),
          child: Opacity(
            key: toastFadeKey(widget.id),
            opacity: t,
            // A card on its way out takes no input: it is a surface the
            // controller has already dropped, and a tap that landed on its
            // button would run an action the user has already spent.
            child: IgnorePointer(ignoring: !widget.shown, child: child),
          ),
        );
      },
    );
  }
}

/// A single toast card: an optional error glyph, the message, an optional Undo
/// button, and a dismiss button. An error card is a live region so a screen
/// reader announces it.
///
/// Stateful for one reason (#258): the card knows whether a pointer is resting
/// on it, and that answer holds both its own countdown and the controller's
/// timer.
class ToastCard extends StatefulWidget {
  const ToastCard({
    required this.toast,
    required this.onDismiss,
    this.onUndo,
    this.onHold,
    this.overflow = 0,
    super.key,
  });

  final ToastData toast;
  final VoidCallback onDismiss;
  final VoidCallback? onUndo;

  /// Told whether a pointer is currently resting on this card, so the caller
  /// can hold the toast's life for as long as it is. Null for a toast with no
  /// deadline to hold.
  final ValueChanged<bool>? onHold;

  /// How many further toasts this card stands in for — the "+N" pill. Zero on
  /// every card that is not the collapsed newest one.
  final int overflow;

  @override
  State<ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<ToastCard> {
  // Hover and touch are tracked apart so a mouse that presses and releases over
  // the card does not report a release it is still hovering through.
  bool _hovered = false;
  bool _pressed = false;

  bool get _held => _hovered || _pressed;

  void _setHold({bool? hovered, bool? pressed}) {
    final nextHovered = hovered ?? _hovered;
    final nextPressed = pressed ?? _pressed;
    if (nextHovered == _hovered && nextPressed == _pressed) return;
    final was = _held;
    setState(() {
      _hovered = nextHovered;
      _pressed = nextPressed;
    });
    // Only the ANSWER changing is news: a mouse pressing and releasing over a
    // card it never left has not stopped resting on it, and must not hand the
    // toast a fresh thirty seconds on every click.
    if (_held != was) widget.onHold?.call(_held);
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.toast;
    final colors = Theme.of(context).colorScheme;
    final isError = toast.variant == ToastVariant.error;
    final bg = isError ? colors.errorContainer : colors.inverseSurface;
    final fg = isError ? colors.onErrorContainer : colors.onInverseSurface;

    return Semantics(
      container: true,
      liveRegion: isError,
      child: MouseRegion(
        onEnter: (_) => _setHold(hovered: true),
        onExit: (_) => _setHold(hovered: false),
        child: Listener(
          // Raw pointer events, not a gesture: holding the card must cost the
          // swipe and the buttons nothing, and a Listener never enters the
          // arena to take a gesture away from them.
          onPointerDown: (_) => _setHold(pressed: true),
          onPointerUp: (_) => _setHold(pressed: false),
          onPointerCancel: (_) => _setHold(pressed: false),
          child: Material(
            color: bg,
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            // So the countdown ends at the card's rounded corner rather than
            // squaring it off.
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (isError) ...<Widget>[
                        Icon(Icons.error_outline, size: 18, color: fg),
                        const SizedBox(width: 10),
                      ],
                      if (widget.overflow > 0) ...<Widget>[
                        _OverflowPill(count: widget.overflow, color: fg),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          toast.message,
                          style: TextStyle(color: fg, fontSize: 13),
                        ),
                      ),
                      if (widget.onUndo != null) ...<Widget>[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: widget.onUndo,
                          style: TextButton.styleFrom(foregroundColor: fg),
                          child: Text(toast.actionLabel ?? 'Undo'),
                        ),
                      ],
                      // A small glyph, but the default 48dp IconButton hit area
                      // is kept (enlarge the target, never the glyph) so a
                      // coarse pointer can dismiss it on a phone.
                      IconButton(
                        onPressed: widget.onDismiss,
                        tooltip: 'Dismiss',
                        iconSize: 18,
                        color: fg,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                // Laid over the card's bottom edge rather than under the row,
                // so a toast that grows a countdown is exactly as tall as one
                // that does not.
                if (toast.hasCountdown)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _ToastCountdown(
                      id: toast.id,
                      life: toast.life!,
                      held: _held,
                      color: fg,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "+N" pill on the card the stack collapsed onto (#258): the toasts behind
/// it are hidden, and this says how many.
class _OverflowPill extends StatelessWidget {
  const _OverflowPill({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // A tooltip rather than a bare glyph: "+2" says how many but not of what,
    // and the pill is not a button, so there is nothing to tap to find out.
    // TalkBack reads the tooltip too, so both pointer classes get the sentence.
    return Tooltip(
      message: '$count more ${count == 1 ? 'notice' : 'notices'}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          '+$count',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// How much of an action toast's life is left, drawn along its bottom edge.
///
/// The span is [life] itself, NOT a span resolved through [Motion]: this is the
/// toast's deadline, and a deadline drawn at zero length would simply be a
/// deadline the user cannot see. Under reduced motion it stops sweeping and
/// steps once a second instead — the same information, without the travel.
class _ToastCountdown extends StatefulWidget {
  const _ToastCountdown({
    required this.id,
    required this.life,
    required this.held,
    required this.color,
  });

  final int id;
  final Duration life;

  /// Whether a pointer is resting on the card. While it is, the drain stops
  /// exactly where it is, because the timer behind it has stopped too.
  final bool held;

  final Color color;

  @override
  State<_ToastCountdown> createState() => _ToastCountdownState();
}

class _ToastCountdownState extends State<_ToastCountdown>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.life,
  )..forward();

  @override
  void didUpdateWidget(covariant _ToastCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.held == oldWidget.held) return;
    if (widget.held) {
      _c.stop();
    } else {
      // From zero, not from where it stopped: [ToastController.release] hands
      // the toast its whole life back, and the bar has to say the same thing
      // the timer is going to do.
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stepped = !Motion.of(context).enabled;
    final steps = widget.life.inSeconds;
    return RepaintBoundary(
      // The longest-running animation in the app by an order of magnitude: an
      // undo toast keeps this ticking for thirty seconds. Its own layer, so
      // those frames repaint a 3dp line and not the card — and not the list
      // behind it — on a phone that is otherwise idle.
      child: SizedBox(
        height: kToastCountdownThickness,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            var left = (1 - _c.value).clamp(0.0, 1.0);
            if (stepped && steps > 0) left = (left * steps).ceil() / steps;
            return FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: left,
              child: ColoredBox(
                key: toastCountdownKey(widget.id),
                color: widget.color.withValues(alpha: 0.55),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The app-wide toast controller. Disposed with the root scope.
final toastControllerProvider = Provider<ToastController>((ref) {
  final controller = ToastController();
  ref.onDispose(controller.dispose);
  return controller;
});
