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

import 'package:async/async.dart' show RestartableTimer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'haptics.dart';

/// How a toast reads: a neutral [info]/undo notice, or a red [error].
enum ToastVariant { info, error }

/// How long an error toast lives before auto-dismissing.
const Duration kErrorToastDuration = Duration(seconds: 5);

/// How long a plain info toast lives.
const Duration kInfoToastDuration = Duration(seconds: 4);

/// How long an undo toast stays reachable before it lapses.
const Duration kUndoToastDuration = Duration(seconds: 30);

/// One entry in the stack. Immutable; the controller owns the list and timers.
class ToastData {
  const ToastData({
    required this.id,
    required this.message,
    required this.variant,
    this.onUndo,
    this.actionLabel,
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
class ToastStack extends StatelessWidget {
  const ToastStack({
    required this.controller,
    this.haptics = const NoHaptics(),
    super.key,
  });

  final ToastController controller;

  /// See [ToastOverlay.haptics].
  final Haptics haptics;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final toasts = controller.toasts;
        if (toasts.isEmpty) return const SizedBox.shrink();
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
                    for (final t in toasts)
                      Padding(
                        key: ValueKey<int>(t.id),
                        padding: const EdgeInsets.only(top: 8),
                        child: ToastCard(
                          toast: t,
                          onUndo: t.onUndo == null
                              ? null
                              : () {
                                  // An UNDO (the unlabelled button) is a
                                  // reversal and is felt; a labelled action is
                                  // a jump and is not (#257).
                                  if (t.actionLabel == null) haptics.confirm();
                                  controller._undo(t);
                                },
                          onDismiss: () => controller.dismiss(t.id),
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
}

/// A single toast card: an optional error glyph, the message, an optional Undo
/// button, and a dismiss button. An error card is a live region so a screen
/// reader announces it.
class ToastCard extends StatelessWidget {
  const ToastCard({
    required this.toast,
    required this.onDismiss,
    this.onUndo,
    super.key,
  });

  final ToastData toast;
  final VoidCallback onDismiss;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isError = toast.variant == ToastVariant.error;
    final bg = isError ? colors.errorContainer : colors.inverseSurface;
    final fg = isError ? colors.onErrorContainer : colors.onInverseSurface;

    return Semantics(
      container: true,
      liveRegion: isError,
      child: Material(
        color: bg,
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isError) ...<Widget>[
                Icon(Icons.error_outline, size: 18, color: fg),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  toast.message,
                  style: TextStyle(color: fg, fontSize: 13),
                ),
              ),
              if (onUndo != null) ...<Widget>[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onUndo,
                  style: TextButton.styleFrom(foregroundColor: fg),
                  child: Text(toast.actionLabel ?? 'Undo'),
                ),
              ],
              // A small glyph, but the default 48dp IconButton hit area is kept
              // (enlarge the target, never the glyph) so a coarse pointer can
              // dismiss it on a phone.
              IconButton(
                onPressed: onDismiss,
                tooltip: 'Dismiss',
                iconSize: 18,
                color: fg,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
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
