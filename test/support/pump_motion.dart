// One clock discipline for every frame-by-frame motion test (#250).
//
// Motion tests fail in two ways, and both used to be a matter of how the
// author happened to write their pumps:
//
//   • `pumpAndSettle()` hides WHEN something happened — a motion that takes a
//     second and a half settles just as green as one that takes 200ms — and it
//     hangs outright against a repeating animation or a focused text field;
//   • a hand-written `pump(const Duration(milliseconds: 130))` re-states a
//     duration the widget owns, so the test keeps passing after the widget's
//     motion is re-timed, and stops meaning anything.
//
// So a motion test names the MOTION (a token from MotionDurations) and lets
// this helper drive the clock across it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Advance a running motion of length [motion].
///
/// One frame to let the animation start, then the span itself. At the default
/// [fraction] of 1 the motion is driven PAST its end (a millisecond of slack,
/// so the last frame is the resting one); a smaller fraction lands the clock
/// mid-flight, where the frame under test is one the user actually sees while
/// the thing is moving.
///
/// A zero [motion] — what `Motion.of` hands back under "remove animations" —
/// still pumps the two frames, so a reduced-motion test and a full-motion test
/// are the same test with a different [MediaQueryData.disableAnimations].
Future<void> pumpMotion(
  WidgetTester tester,
  Duration motion, {
  double fraction = 1,
}) async {
  await tester.pump();
  await tester.pump(
    fraction >= 1
        ? motion + const Duration(milliseconds: 1)
        : motion * fraction,
  );
}
