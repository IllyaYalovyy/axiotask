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
// protects nothing (#172). Timers are ordinary `Timer`s (deterministic under
// `tester.pump`) and are cancelled on dismiss and on [ToastController.dispose].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });

  /// A process-unique id (the stack key and the dismiss handle).
  final int id;

  /// The user-visible text (already redacted for errors).
  final String message;

  /// Info vs error styling.
  final ToastVariant variant;

  /// The revert action; when non-null the toast shows an Undo button.
  final VoidCallback? onUndo;
}

/// Owns the live toast list and each toast's auto-dismiss timer. A
/// [ChangeNotifier] so the [ToastStack] rebuilds on any change; not tied to a
/// widget, so a background sync or a command handler can raise a toast without
/// a [BuildContext].
class ToastController extends ChangeNotifier {
  final List<ToastData> _toasts = <ToastData>[];
  int _seq = 0;
  bool _disposed = false;

  /// The live stack, oldest first.
  List<ToastData> get toasts => List<ToastData>.unmodifiable(_toasts);

  /// Show a toast; returns its id. [duration] `null` means it persists until
  /// dismissed (or reverted).
  int show(
    String message, {
    ToastVariant variant = ToastVariant.info,
    VoidCallback? onUndo,
    Duration? duration,
  }) {
    final id = _seq++;
    _toasts.add(
      ToastData(id: id, message: message, variant: variant, onUndo: onUndo),
    );
    if (duration != null) {
      // Auto-dismiss via a controllable delay (never a raw Timer — banned below
      // lib/ as an uncontrollable time source). The callback is idempotent: it
      // only removes the toast if it is still present and the controller is
      // alive, so an early manual dismiss or disposal makes it a harmless no-op.
      unawaited(
        Future<void>.delayed(duration).then((_) {
          if (!_disposed && _toasts.any((t) => t.id == id)) dismiss(id);
        }),
      );
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

  /// Show an undo toast: a message plus an Undo button that runs [onUndo] and
  /// then dismisses the toast. Lasts [duration] (default 30s) if not acted on.
  int showUndo(
    String message,
    VoidCallback onUndo, {
    Duration duration = kUndoToastDuration,
  }) {
    return show(message, onUndo: onUndo, duration: duration);
  }

  /// Remove toast [id] (a no-op if it is already gone). Any still-pending
  /// auto-dismiss for it becomes a no-op (the guarded callback re-checks).
  void dismiss(int id) {
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
    super.key,
  });

  final ToastController controller;
  final Widget child;

  @override
  State<ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<ToastOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) => ToastStack(controller: widget.controller),
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
  const ToastStack({required this.controller, super.key});

  final ToastController controller;

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
                              : () => controller._undo(t),
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
                  child: const Text('Undo'),
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
