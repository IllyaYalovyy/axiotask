// The haptics double for the #257 vocabulary suites.
//
// It stands in for the DEVICE seam (`hapticsDeviceProvider`), never for the
// pref-gated `hapticsProvider` — so a test that silences haptics through the
// pref still asserts against this recorder and sees an EMPTY list. Recording
// what the app asked the device for is the only headless evidence there is:
// intensity itself can only be judged with a phone in hand.

import 'package:axiotask/src/ui/haptics.dart';

/// Records the vocabulary a gesture fired, in order.
class FakeHaptics implements Haptics {
  /// Every event this seam was asked for, oldest first ('tick' | 'confirm' |
  /// 'warn').
  final List<String> events = <String>[];

  @override
  void tick() => events.add('tick');

  @override
  void confirm() => events.add('confirm');

  @override
  void warn() => events.add('warn');

  /// Forget everything recorded so far — used to isolate the gesture under
  /// assertion from the setup gestures that reached it (selecting a row before
  /// a bulk action, say).
  void clear() => events.clear();
}
