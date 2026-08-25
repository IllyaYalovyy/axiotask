// #233 — recovery from a bottom view inset that outlives the keyboard.
//
// On device the shell was seen holding a roughly half-screen bottom inset with
// NO keyboard on screen: `resizeToAvoidBottomInset` dutifully reserved the
// space, so the body occupied the top half, the rest was black, and the FAB
// floated at the phantom boundary while the bottom navigation bar still drew at
// the true bottom of the screen. The state survived normal use — the screen
// simply stayed half dead.
//
// The engine-side trigger was never reproduced (see the issue's on-device repro
// log: back-dismissal, background/restore and detail-field IME cycles all
// recover cleanly), so this is deliberately a RECOVERY contract rather than a
// cause fix. It rests on one thing the app always knows and the platform
// sometimes gets wrong:
//
//   a bottom inset is a keyboard only while something can type into it.
//
// So: when `viewInsets.bottom > 0` while nothing in the app holds text-input
// focus, and that combination holds for [ImeInsetGuard.staleAfter] — an
// eternity next to any IME hide animation — the inset is not a keyboard. The
// guard then asks the platform to hide the IME (the real fix, if the engine
// still believes a keyboard is up) and zeroes the bottom inset for its subtree
// (the guarantee, if the platform does not answer).
//
// What it is NOT: a global inset suppression. A focused field never satisfies
// the stale condition, so the #166 contract — inputs stay above the keyboard —
// is untouched, and the release un-arms the moment the real inset returns to 0.

import 'dart:async' show unawaited;

import 'package:async/async.dart' show RestartableTimer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;

/// Guarantees that a bottom view inset which no focused field can explain is
/// released from [child]'s [MediaQuery], so the body can never stay compressed
/// behind a keyboard that is gone (#233).
class ImeInsetGuard extends StatefulWidget {
  const ImeInsetGuard({required this.child, super.key});

  /// The subtree whose bottom inset is guarded — the whole shell.
  final Widget child;

  /// How long "a bottom inset with nothing focused" must hold before it counts
  /// as stale. Far longer than an IME hide animation (~250ms), so the ordinary
  /// dismissal — where focus drops a frame before the inset finishes
  /// retracting — never trips it; short enough that recovery reads to the user
  /// as the screen simply coming back.
  static const Duration staleAfter = Duration(seconds: 1);

  @override
  State<ImeInsetGuard> createState() => _ImeInsetGuardState();
}

class _ImeInsetGuardState extends State<ImeInsetGuard> {
  /// Armed while the bottom inset is unexplained; firing declares it stale. A
  /// [RestartableTimer] because the repo bans a raw `Timer` below lib/ (see
  /// TESTING.md) and it is cancellable — this one never outlives the shell.
  RestartableTimer? _stale;

  /// The bottom view inset last published to this subtree.
  double _insetBottom = 0;

  /// Whether this subtree is currently being shown a zeroed bottom inset.
  bool _released = false;

  @override
  void initState() {
    super.initState();
    // Focus changes are the other half of the condition: a field taking or
    // losing focus can make an inset explained or unexplained without the
    // metrics moving at all.
    FocusManager.instance.addListener(_reassess);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // [build] depends on the MediaQuery, so this runs on every inset change —
    // no WidgetsBindingObserver needed to hear about the keyboard.
    _insetBottom = MediaQuery.viewInsetsOf(context).bottom;
    _reassess(duringBuildPhase: true);
  }

  @override
  void dispose() {
    _stale?.cancel();
    FocusManager.instance.removeListener(_reassess);
    super.dispose();
  }

  /// True while the bottom inset claims a keyboard that nothing could be typing
  /// into.
  bool get _unexplained => _insetBottom > 0 && !_hasTextInputFocus;

  /// Whether the app's focused node belongs to a text field — the only thing
  /// that legitimately holds a soft keyboard up.
  static bool get _hasTextInputFocus {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null || !focused.mounted) return false;
    // Every Flutter text field hosts its focus node in a [Focus] inside its
    // [EditableText], so the focused node's own context sits under one exactly
    // when the focus is a text input.
    return focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Re-decide whether the inset is explainable. Called from the build phase
  /// (via [didChangeDependencies], where the flag must be set directly — the
  /// build that consumes it has not run yet) and from focus/timer callbacks
  /// (where a rebuild has to be requested).
  void _reassess({bool duringBuildPhase = false}) {
    if (!mounted) return;
    if (_unexplained) {
      // Already released — re-arming would only re-run the same recovery.
      if (_released) return;
      final timer = _stale;
      if (timer == null || !timer.isActive) {
        _stale = RestartableTimer(ImeInsetGuard.staleAfter, _onStale);
      }
      return;
    }
    _stale?.cancel();
    if (!_released) return;
    if (duringBuildPhase) {
      _released = false;
    } else {
      setState(() => _released = false);
    }
  }

  /// The inset has been unexplained for [ImeInsetGuard.staleAfter]: treat it as
  /// stale.
  void _onStale() {
    if (!mounted || !_unexplained) return;
    // Try the real fix first — if the engine still holds a shown IME, this
    // retracts the inset at its source rather than masking it.
    unawaited(
      SystemChannels.textInput
          .invokeMethod<void>('TextInput.hide')
          .catchError((Object _) {}),
    );
    setState(() => _released = true);
  }

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    if (!_released || data.viewInsets.bottom == 0) return widget.child;
    // The "no keyboard" MediaQuery: the bottom inset is gone AND the bottom
    // padding it had swallowed (the gesture pill / navigation bar) is handed
    // back, so a SafeArea below still clears what it cleared before the phantom
    // inset appeared.
    return MediaQuery(
      data: data.copyWith(
        viewInsets: data.viewInsets.copyWith(bottom: 0),
        padding: data.padding.copyWith(bottom: data.viewPadding.bottom),
      ),
      child: widget.child,
    );
  }
}
