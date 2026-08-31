// #258 golden: the toast card vocabulary, and specifically the countdown the
// Undo toast grew.
//
// The widget tests pin the countdown's BEHAVIOUR (it drains, it holds under a
// pointer, it steps under reduced motion). Only a picture answers the question
// the change was about: does a thin line along the bottom edge read as "this is
// going away" without reading as a progress bar, does the "+2" pill read as a
// count rather than a button, and does a card that has nothing to act on stay
// exactly as quiet as it was? The error card is the control — it must carry no
// line at all.
//
// This is a NEW baseline, created by intent with the feature (issue #258), not
// a regeneration of an existing one: no golden rendered a toast before.
//
// Determinism: [ToastCard] is rendered directly, so no [ToastController] and no
// auto-dismiss timer exists; the countdown is pumped to a fixed point inside its
// 30-second life, and alchemist's extra post-resize frame advances it by
// nothing. Nothing here reads the clock, is hovered, or is focused.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:axiotask/src/ui/toast.dart';
import 'package:flutter/material.dart';

/// Halfway through the undo window — the state the bar exists to show. A full
/// bar and an empty one are both indistinguishable from "no bar at all having
/// happened yet", so the snapshot is taken where the drain is visible.
final _halfway = kUndoToastDuration ~/ 2;

Widget _card(ToastData toast, {int overflow = 0}) => ToastCard(
  toast: toast,
  overflow: overflow,
  onUndo: toast.onUndo == null ? null : () {},
  onDismiss: () {},
);

Widget _cards(ThemeData theme, Size size) => MediaQuery(
  // A fixed MediaQuery for the same reason the #242 golden pins one: alchemist
  // resizes the surface after `pumpBeforeTest` and pumps another frame, and
  // nothing in this subtree should change when it does.
  data: MediaQueryData(size: size),
  child: Theme(
    data: theme.copyWith(platform: TargetPlatform.linux),
    child: Builder(
      builder: (context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              // An undo toast, halfway through its life: message, Undo, ×, and
              // the countdown along the bottom edge.
              _card(
                ToastData(
                  id: 0,
                  message: 'Deleted "Book the dentist"',
                  variant: ToastVariant.info,
                  onUndo: () {},
                  life: kUndoToastDuration,
                ),
              ),
              const SizedBox(height: 8),
              // The collapsed card: it stands in for two more toasts and says
              // so with the "+2" pill.
              _card(
                const ToastData(
                  id: 1,
                  message: 'Moved to Personal',
                  variant: ToastVariant.info,
                ),
                overflow: 2,
              ),
              const SizedBox(height: 8),
              // The control: nothing to act on, so no countdown.
              _card(
                const ToastData(
                  id: 2,
                  message: 'Sync failed — the details are in the log.',
                  variant: ToastVariant.error,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  // Wide enough that no message wraps in the TEST font, which measures far
  // wider than the production one (see the widget-test-font memory).
  const size = Size(620, 240);

  goldenTest(
    'toast cards — undo countdown, collapsed pill, error',
    fileName: 'toast_cards',
    // A FIXED point inside the countdown, never pumpAndSettle: an action
    // toast's bar animates for its whole 30-second life, so settling would
    // snapshot an empty bar (and take 30 seconds of frames to get there).
    pumpBeforeTest: (tester) => tester.pump(_halfway),
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'undo (countdown at half) / collapsed "+2" / error',
          constraints: BoxConstraints.tight(size),
          child: _cards(buildLightTheme(), size),
        ),
      ],
    ),
  );
}
