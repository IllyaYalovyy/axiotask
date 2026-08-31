// The motion vocabulary (#250) — the ONE place a duration is chosen, the ONE
// place a curve is named, and the ONE place the reduced-motion rule is applied.
//
// Ten motion tasks (#241, #251–#260) were queued behind this file for a
// reason: ten animations each picking the duration and easing that felt right
// on the day is ten dialects, and a user reads that as incoherence long before
// they could name it. So:
//
//   • durations come from [MotionDurations] — a four-step scale, plus the
//     handful of BESPOKE spans that predate this file and are documented one
//     by one below;
//   • curves come from [MotionCurves] — the Material 3 set: emphasized easing
//     for something MOVING, a decelerating enter, an accelerating exit.
//     Nothing bounces, springs or overshoots except the FAB's landing, which
//     is a deliberate exception that already shipped;
//   • a widget never reads either directly: it asks [Motion.of] for the span,
//     and under "remove animations" (Android) / reduced motion (desktop) every
//     span it gets back is [Duration.zero]. The end state is then reached in
//     the same frame — nothing is skipped, cancelled or delayed, only the
//     TRAVEL goes away. A motion that has no other way to be seen (a flash, a
//     sweep) is exactly the motion a user with that setting asked not to see.
//
// The rule is enforced by grep as well as by review: `Duration(milliseconds:`
// appears nowhere under lib/src/ui except in this file.

import 'package:flutter/widgets.dart';

/// The raw motion scale — the spans BEFORE [Motion] applies the reduced-motion
/// rule.
///
/// Read one of these directly only where a `const` is unavoidable (a widget's
/// static default, a test naming the motion it drives); anything that actually
/// runs takes its span from [Motion.of].
abstract final class MotionDurations {
  /// 100ms — a state layer, a flash, a colour settling. Short enough that the
  /// eye reads the end state rather than the change.
  static const Duration short = Duration(milliseconds: 100);

  /// 200ms — a small element or a piece of chrome entering or leaving.
  static const Duration medium = Duration(milliseconds: 200);

  /// 300ms — list choreography, pane and route transitions: things that move
  /// far enough that the eye needs to follow them.
  static const Duration long = Duration(milliseconds: 300);

  /// 400ms — a container becoming another container. The longest span in the
  /// app; anything slower stops being feedback and starts being a wait.
  static const Duration emphasized = Duration(milliseconds: 400);

  /// 40ms — the OFFSET between one animating list row and the next (#251), not
  /// a span of its own: it delays a motion, it does not lengthen one. The
  /// smallest gap at which a batch of rows reads as a cascade instead of one
  /// block; much more and the list starts dealing cards. Eight rows is the cap,
  /// so the last one it allows waits 280ms before it begins.
  static const Duration rowStagger = Duration(milliseconds: 40);

  /// 300ms — the grace the list gives the store's FIRST snapshot before it
  /// admits to waiting (#260).
  ///
  /// A THRESHOLD, not a span of motion: nothing travels for 300ms, and it is
  /// never resolved through [Motion] — a user who turned animations off did
  /// not ask to be shown placeholder rows 300ms sooner. It lives here anyway,
  /// because this file is where a duration in this app is chosen.
  ///
  /// Measured, not guessed: a file-backed first snapshot costs 7–13ms at
  /// 50–1000 tasks and 32ms at 5000 on this developer machine
  /// (designs/cold-start.md §"First snapshot"). The skeleton is therefore a
  /// safety net for a pathological launch — a cold spinning disk, a phone
  /// thrashing — and not a state the app expects to render.
  static const Duration firstSnapshotGrace = Duration(milliseconds: 300);

  // ── Bespoke spans ────────────────────────────────────────────────────────
  // Each of these shipped before the scale existed and is kept here at its
  // EXACT previous value: #250 defines the vocabulary, it changes no motion
  // the user can see. Each says why it is not simply `short` or `long`.

  /// 120ms — the FAB's leave and return (#234). Deliberately shorter than the
  /// composer's own route transition: the FAB has to be gone before the sheet
  /// unfolds far enough to reach the corner, or the two read as two surfaces
  /// trading places instead of one becoming the other.
  static const Duration fabTransition = Duration(milliseconds: 120);

  /// 500ms — a nav-bar destination going from unselected to selected (#237).
  /// The framework's own `NavigationBar` indicator span: the hand-rolled bar
  /// matches it so the two are indistinguishable in motion as well as pixels.
  static const Duration navSelection = Duration(milliseconds: 500);

  /// 140ms — the first beat of the completion sequence (#241): the strike
  /// sweep, fade and shrink of a row that was just ticked.
  static const Duration completionSettle = Duration(
    milliseconds: _completionSettleMs,
  );

  /// 180ms — the second beat (#241): a departing row folding its height away
  /// while the rows below slide up.
  static const Duration completionCollapse = Duration(
    milliseconds: _completionCollapseMs,
  );

  /// Settle plus collapse — the completion sequence end to end.
  static const Duration completionSequence = Duration(
    milliseconds: _completionSettleMs + _completionCollapseMs,
  );

  /// Where the settle ends inside [completionSequence] — the point a completed
  /// row that STAYS on screen rests at.
  static const double completionSettleFraction =
      _completionSettleMs / (_completionSettleMs + _completionCollapseMs);

  static const int _completionSettleMs = 140;
  static const int _completionCollapseMs = 180;

  // ── Composed spans ───────────────────────────────────────────────────────
  // Not new values: each is two or three of the steps above, run back to back
  // by ONE controller, with a fraction naming where each beat ends. The
  // completion sequence above is the same shape; these follow it.

  /// The quiet sync line's completion, end to end (#255): the determinate FILL
  /// to the end ([short]) followed by the FADE out ([medium]).
  static const Duration syncLineFinish = Duration(
    milliseconds: _syncLineFillMs + _syncLineFadeMs,
  );

  /// Where the fill ends inside [syncLineFinish] — past it the line is full
  /// width and only fading.
  static const double syncLineFillFraction =
      _syncLineFillMs / (_syncLineFillMs + _syncLineFadeMs);

  static const int _syncLineFillMs = 100;
  static const int _syncLineFadeMs = 200;

  /// The footer's sync check-mark, end to end (#255): the stroke DRAWING in
  /// ([medium]), a HOLD long enough for a glance to land on it ([long]), then
  /// the FADE back to the status dot ([medium]). The hold is what makes it a
  /// confirmation rather than a blink — a mark that draws and immediately
  /// leaves is gone before the eye reaches the footer.
  static const Duration syncCheck = Duration(
    milliseconds: _syncCheckDrawMs + _syncCheckHoldMs + _syncCheckFadeMs,
  );

  /// Where the stroke finishes inside [syncCheck].
  static const double syncCheckDrawFraction =
      _syncCheckDrawMs /
      (_syncCheckDrawMs + _syncCheckHoldMs + _syncCheckFadeMs);

  /// Where the hold ends inside [syncCheck] — past it the mark is fading.
  static const double syncCheckHoldFraction =
      (_syncCheckDrawMs + _syncCheckHoldMs) /
      (_syncCheckDrawMs + _syncCheckHoldMs + _syncCheckFadeMs);

  static const int _syncCheckDrawMs = 200;
  static const int _syncCheckHoldMs = 300;
  static const int _syncCheckFadeMs = 200;

  /// The expanded layout's detail pane arriving, end to end (#253): the pane
  /// SLIDING in from the end edge while the list eases to its narrower width
  /// ([long]), then the open-row highlight (#221) FADING in once the pane has
  /// landed ([short]).
  ///
  /// One span on one controller rather than two animations that happen to be
  /// ordered, so the highlight can never appear before the pane it belongs to —
  /// and so the reverse costs nothing to define: the highlight leaves first,
  /// the pane slides out after it.
  static const Duration detailPane = Duration(
    milliseconds: _detailPaneSlideMs + _detailHighlightMs,
  );

  /// Where the pane's slide ends inside [detailPane]. Before it the pane is
  /// still travelling and the row highlight is not there at all; after it the
  /// pane has landed and only the highlight is still arriving.
  static const double detailPaneSlideFraction =
      _detailPaneSlideMs / (_detailPaneSlideMs + _detailHighlightMs);

  static const int _detailPaneSlideMs = 300;
  static const int _detailHighlightMs = 100;
}

/// The easing vocabulary. Material 3's three, and one documented exception.
abstract final class MotionCurves {
  /// Something already on screen MOVING to a new place: M3's emphasized
  /// easing, which leaves slowly and arrives decisively.
  static const Curve standard = Curves.easeInOutCubicEmphasized;

  /// Something ARRIVING: fast at first, settling into place.
  static const Curve enter = Curves.easeOutCubic;

  /// Something LEAVING: it accelerates away and does not ask to be watched.
  static const Curve exit = Curves.easeIn;

  /// The one overshoot in the app: the FAB "lands" when it returns (#234).
  /// Nothing else may bounce — an overshoot on a row, a pane or a sheet reads
  /// as a wobble, not as character.
  static const Curve fabLanding = Curves.easeOutBack;
}

/// The motion a given [BuildContext] is allowed to have.
///
/// Obtained with [Motion.of], which depends on
/// [MediaQueryData.disableAnimations] — so a widget that reads its spans here
/// rebuilds by itself when the platform setting is turned on or off.
@immutable
class Motion {
  const Motion._({required this.enabled});

  /// Motion as designed.
  static const Motion full = Motion._(enabled: true);

  /// Reduced motion: every span is [Duration.zero].
  static const Motion none = Motion._(enabled: false);

  /// The motion this [context] may play — [none] when the platform asks for
  /// animations to be removed, [full] otherwise.
  static Motion of(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? none : full;

  /// Whether motion actually travels here. Useful for the rare decision that
  /// is not a duration (skipping a staggered entrance outright, say).
  final bool enabled;

  /// Any span from [MotionDurations], under this context's rule — the way to
  /// reach a bespoke token such as [MotionDurations.fabTransition].
  Duration resolve(Duration token) => enabled ? token : Duration.zero;

  /// [MotionDurations.short], under this context's rule.
  Duration get short => resolve(MotionDurations.short);

  /// [MotionDurations.medium], under this context's rule.
  Duration get medium => resolve(MotionDurations.medium);

  /// [MotionDurations.long], under this context's rule.
  Duration get long => resolve(MotionDurations.long);

  /// [MotionDurations.emphasized], under this context's rule.
  Duration get emphasized => resolve(MotionDurations.emphasized);
}
