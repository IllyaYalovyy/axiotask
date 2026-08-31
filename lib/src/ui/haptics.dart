// The haptic vocabulary (#257) — the ONE seam through which axiotask ever
// vibrates the device.
//
// On Android a tactile answer is the cheapest "it happened" signal there is,
// and its absence is most of what makes a phone app feel unfinished. But the
// failure in the other direction is worse: a device that buzzes on every
// scroll, every navigation, every once-a-minute background poll is a device the
// user turns haptics off on entirely. So the vocabulary is CLOSED — three tones
// and a fixed list of events, written down here and asserted in
// `test/ui/haptics_test.dart`:
//
//   tick    — checkbox complete/uncomplete, selection toggle, quick-date apply,
//             drag lift, drag drop, a swipe crossing its action threshold;
//   confirm — delete (single or bulk), Undo;
//   warn    — reserved. NO event maps to it today; it exists so a future
//             destructive-failure signal has a named tone instead of an
//             ad-hoc [HapticFeedback] call growing somewhere else.
//
// Nothing on scroll, navigation, sync, toasts or typing. A new call site is a
// review finding unless the vocabulary above grows with it.
//
// Two providers, deliberately:
//   • [hapticsDeviceProvider] is the raw device seam — the platform
//     implementation on Android, the no-op everywhere else (desktop, and the
//     test host, which is a desktop process). Tests override THIS with a
//     recorder;
//   • [hapticsProvider] is what the UI reads: the device seam behind the
//     `haptics` pref. Because the gate sits above the device seam and not
//     inside the call sites, a test can silence the pref and still assert
//     against the same recorder — and see nothing.
//
// The system-wide "touch feedback" setting is honoured by the platform itself;
// the pref here is axiotask's own opt-out on top of it.

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/prefs_controller.dart';

/// The three-tone haptic vocabulary. See the file header for the events each
/// tone is allowed to answer.
abstract interface class Haptics {
  /// A light tap: something small landed exactly where the finger was.
  void tick();

  /// A firmer beat: something consequential (and reversible) happened.
  void confirm();

  /// The heaviest tone. Reserved — no event maps to it yet.
  void warn();
}

/// The no-op: what every non-Android platform, and every test that has not
/// asked otherwise, resolves to. Never touches a platform channel.
class NoHaptics implements Haptics {
  const NoHaptics();

  @override
  void tick() {}

  @override
  void confirm() {}

  @override
  void warn() {}
}

/// The Android implementation, over Flutter's [HapticFeedback] channel.
///
/// Fire-and-forget: the call is never awaited by a gesture handler (a tap must
/// not wait on a vibration) and a channel failure is swallowed — a device with
/// no haptic engine, or an OS that refuses the request, must never turn a
/// checkbox tap into an unhandled async error.
class PlatformHaptics implements Haptics {
  const PlatformHaptics();

  @override
  void tick() => _fire(HapticFeedback.lightImpact);

  @override
  void confirm() => _fire(HapticFeedback.mediumImpact);

  @override
  void warn() => _fire(HapticFeedback.heavyImpact);

  static void _fire(Future<void> Function() impact) =>
      unawaited(impact().catchError((Object _) {}));
}

/// The implementation [android] gets. Android is the only platform axiotask
/// ships with a haptic engine; the desktop build must never reach for one.
Haptics hapticsFor({required bool android}) =>
    android ? const PlatformHaptics() : const NoHaptics();

/// The raw device seam, before the pref gate. Overridden in tests with a
/// recorder; on the Linux gate host it resolves to [NoHaptics] on its own, so
/// no widget test ever fires a real platform call.
final hapticsDeviceProvider = Provider<Haptics>(
  (ref) => hapticsFor(android: Platform.isAndroid),
);

/// The haptics the UI fires: [hapticsDeviceProvider] behind the `haptics`
/// pref. With the pref off this is the no-op, so every event in the vocabulary
/// goes silent at once and no call site needs to know about the pref.
final hapticsProvider = Provider<Haptics>((ref) {
  final enabled = ref.watch(prefsControllerProvider.select((p) => p.haptics));
  return enabled ? ref.watch(hapticsDeviceProvider) : const NoHaptics();
});
