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

/// The editors that can hold typed-but-unsaved content.
enum PendingEdit { detail, quickAdd }

/// See the file header. Holds at most one live flush per [PendingEdit] (only one
/// detail and one quick-add field are ever mounted at a time).
class PendingEdits {
  final _flushers = <PendingEdit, VoidCallback>{};

  /// Register [flush] as the current persist-now action for [key].
  void register(PendingEdit key, VoidCallback flush) => _flushers[key] = flush;

  /// Retract [flush] for [key] — a no-op if a newer editor already replaced it
  /// (mount-before-unmount across a view switch must not drop the new one).
  void unregister(PendingEdit key, VoidCallback flush) {
    if (identical(_flushers[key], flush)) _flushers.remove(key);
  }

  /// Persist a single editor's pending edits (the detail-close path).
  void flush(PendingEdit key) => _flushers[key]?.call();

  /// Persist every registered editor's pending edits (the backgrounded path).
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
