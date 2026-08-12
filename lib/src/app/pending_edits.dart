// Edit-loss protection (#183). A tiny registry of "persist my in-progress edits
// right now" callbacks, so the app can save typed-but-unsaved field content on
// the two paths that bypass the normal blur-save:
//
//   • the Android system back that closes the open detail — a go_router
//     navigation via the shell's PopScope, NOT the panel's own Back button, so
//     it never runs the panel's flush-on-close and dispose kills the focused
//     node before a blur can persist anything; and
//   • the app being backgrounded (paused / hidden), where the OS may kill the
//     process before any blur fires.
//
// Each editor (the task detail, the always-visible quick-add draft) registers
// its flush while mounted and retracts it on dispose. The close-detail handler
// flushes only the detail; the lifecycle listener flushes everything.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The editors that can hold typed-but-unsaved content: the detail panel's
/// title/notes fields, the always-visible quick-add draft, and a row's inline
/// rename editor (G4 #183 — a mid-typing rename that no blur will reach).
enum PendingEdit { detail, quickAdd, rename }

/// See the file header. Holds at most one live flush per [PendingEdit] (only one
/// detail, one quick-add, and one inline-rename editor are ever mounted at a
/// time).
class PendingEdits {
  final _flushers = <PendingEdit, VoidCallback>{};

  // The detail panel's flush-AND-DISCARD funnel, kept SEPARATE from its
  // background flush (the [PendingEdit.detail] entry above). The system-back
  // that closes the panel must save the fields AND discard an abandoned blank
  // subtask — exactly as the panel's own Back button does (G4 #183). But the
  // backgrounded path ([flushAll]) must only SAVE: it must never silently delete
  // a task the user merely stepped away from. So the close funnel lives here,
  // invoked by [flushDetailClose] alone and never by [flushAll].
  VoidCallback? _detailClose;

  /// Register [flush] as the current persist-now action for [key].
  void register(PendingEdit key, VoidCallback flush) => _flushers[key] = flush;

  /// Retract [flush] for [key] — a no-op if a newer editor already replaced it
  /// (mount-before-unmount across a view switch must not drop the new one).
  void unregister(PendingEdit key, VoidCallback flush) {
    if (identical(_flushers[key], flush)) _flushers.remove(key);
  }

  /// Register the detail panel's flush-and-discard funnel (the system-back
  /// close path — see [_detailClose]).
  void registerDetailClose(VoidCallback flush) => _detailClose = flush;

  /// Retract the detail-close funnel — a no-op once a newer panel replaced it.
  void unregisterDetailClose(VoidCallback flush) {
    if (identical(_detailClose, flush)) _detailClose = null;
  }

  /// Persist a single editor's pending edits (the detail-close path).
  void flush(PendingEdit key) => _flushers[key]?.call();

  /// Run the detail panel's flush-and-discard funnel (the system-back that
  /// closes the panel), so an abandoned blank subtask is discarded on system
  /// back exactly as on the panel's own Back button (G4 #183).
  void flushDetailClose() => _detailClose?.call();

  /// Persist every registered editor's pending edits (the backgrounded path).
  /// Deliberately SAVE-only: it never runs the detail-close discard funnel, so
  /// backgrounding a blank subtask keeps it rather than deleting it (G4 #183).
  void flushAll() {
    for (final f in [..._flushers.values]) {
      f();
    }
  }
}

/// App-wide, so the shell and the lifecycle listener share one registry. A plain
/// [Provider] — no override needed; tests read the same instance.
final pendingEditsProvider = Provider<PendingEdits>((ref) => PendingEdits());

/// Wraps [child] and flushes every registered editor once when the app is
/// backgrounded (the first paused/hidden transition), re-arming on resume so a
/// later backgrounding flushes again. One flush per backgrounding avoids the
/// double-submit a paused-then-hidden pair would otherwise cause for the
/// quick-add draft.
class PendingEditsLifecycleFlusher extends ConsumerStatefulWidget {
  const PendingEditsLifecycleFlusher({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PendingEditsLifecycleFlusher> createState() =>
      _PendingEditsLifecycleFlusherState();
}

class _PendingEditsLifecycleFlusherState
    extends ConsumerState<PendingEditsLifecycleFlusher> {
  late final AppLifecycleListener _listener;
  // Captured once so a lifecycle event that fires after this widget deactivates
  // (teardown, hot restart) never does an unsafe ancestor lookup via `ref`.
  late final PendingEdits _pending;
  bool _flushed = false;

  @override
  void initState() {
    super.initState();
    _pending = ref.read(pendingEditsProvider);
    _listener = AppLifecycleListener(onStateChange: _onStateChange);
  }

  void _onStateChange(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (!_flushed) {
          _flushed = true;
          _pending.flushAll();
        }
      case AppLifecycleState.resumed:
        _flushed = false;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
