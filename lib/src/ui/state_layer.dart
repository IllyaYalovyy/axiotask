// The ONE interaction-state surface (#259) — what a tappable thing in this app
// says while a pointer or the keyboard is on it.
//
// "Responsive" at the millisecond level is not motion, it is STATE: a surface
// that answers the pointer before it answers the tap. The app had that only
// where it had inherited it — a Material button, a ListTile — and nowhere it
// had built its own affordance. A task row, the app's densest and most-used
// control, gave a mouse nothing on hover, a finger nothing on press, and a
// keyboard nothing at all: Tab could not even reach it.
//
// So there is one wrapper, and it is the only place the three states are
// spelled out:
//
//   • HOVER — the M3 state layer, `onSurface` at 8%. A fine pointer only; a
//     finger never hovers, which is exactly why press has to carry its own
//     weight below.
//   • PRESS — `onSurface` at 10%, under a ripple bounded to the surface's own
//     shape. The ripple is the framework's, so a row and a FilledButton press
//     the same way on the same platform (M3 resolves it per platform: the
//     sparkle on Android, the ripple everywhere else).
//   • FOCUS — the same 10% layer PLUS a 2dp [ColorScheme.primary] ring drawn
//     inside the surface's bounds. The wash alone is indistinguishable from
//     hover, and "where is the keyboard" is a question a wash cannot answer.
//
// Two rules the wrapper exists to keep, which no per-widget hand-rolled
// InkWell was keeping:
//
//   1. NO REFLOW. Nothing here occupies layout: the ring is an overlay in a
//      passthrough [Stack] and the washes are ink features. A surface is
//      exactly the same size at rest, hovered, focused and pressed — asserted
//      in `test/ui/state_layer_test.dart`, because a control that grows under
//      the pointer moves the thing the user was aiming at.
//   2. NO COLOUR LITERALS AT THE CALL SITE. Every state colour is derived from
//      the [ColorScheme] here. A surface that wants to look interactive asks
//      for a [StateLayer]; it does not pick an opacity.
//
// Layering: the wrapper carries its OWN transparent [Material]. Ink features
// paint on the nearest ancestor Material, i.e. underneath everything between
// it and the surface — which for a task row means underneath the row's own
// selection / open-in-detail wash, which is opaque in the light theme. A local
// Material puts the state layer where M3 puts it: above the container's colour,
// below its content.
//
// Reduced motion keeps every state and drops the TRAVEL (#250): the hover and
// focus layers arrive in the same frame instead of over a fade, and the ripple
// resolves to [NoSplash] — a spreading circle is the one part of a press that
// is animation rather than information.

import 'package:flutter/material.dart';

import 'motion.dart';

/// The width of the keyboard-focus ring. 2dp: 1dp reads as a rendering seam at
/// desktop scale, 3dp starts to look like a selected state.
const double _focusRingWidth = 2;

/// The M3 state-layer opacities on [ColorScheme.onSurface] — the ONE place
/// these numbers appear.
const double _hoverOpacity = 0.08;
const double _pressOpacity = 0.10;
const double _focusOpacity = 0.10;

/// The state-layer colour for each interaction state, resolved in the M3 order
/// (a pressed pointer is also a hovering one, and press wins).
WidgetStateProperty<Color?> _stateLayerOverlay(ColorScheme scheme) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return scheme.onSurface.withValues(alpha: _pressOpacity);
      }
      if (states.contains(WidgetState.hovered)) {
        return scheme.onSurface.withValues(alpha: _hoverOpacity);
      }
      if (states.contains(WidgetState.focused)) {
        return scheme.onSurface.withValues(alpha: _focusOpacity);
      }
      return null;
    });

/// Wraps [child] in the app's hover / press / focus states.
///
/// The surface is [child]'s exact size — this adds a ripple, a wash, a focus
/// ring and (on a fine pointer) the click cursor, and NOTHING to the layout.
/// Give it the [borderRadius] the surface is already drawn with so the ripple
/// and the ring follow the same shape as its background; the default is square,
/// which is what a full-bleed list row is.
class StateLayer extends StatefulWidget {
  const StateLayer({
    required this.onTap,
    required this.child,
    this.onDoubleTap,
    this.borderRadius,
    super.key,
  });

  /// The action. Required — a [StateLayer] with nothing to do would be a
  /// surface that lights up and then does nothing, which is worse than a flat
  /// one. A surface whose action is conditional builds the plain child instead.
  final VoidCallback onTap;

  /// A second tap on the same surface (the task row's desktop rename). Note
  /// that wiring it makes every single tap here wait out the double-tap window,
  /// so it belongs only where that trade was already made.
  final VoidCallback? onDoubleTap;

  /// The shape the ripple is clipped to and the focus ring is drawn along.
  final BorderRadius? borderRadius;

  final Widget child;

  @override
  State<StateLayer> createState() => _StateLayerState();
}

class _StateLayerState extends State<StateLayer> {
  // The wrapper owns the ink surface's focus node so the RING can be driven by
  // PRIMARY focus. `InkWell.onFocusChange` reports `hasFocus`, which is also
  // true while a focusable CHILD holds the keyboard (a row's checkbox, its date
  // button) — a ring on that would draw a second outline around the thing the
  // keyboard is actually on. So the two states divide the job the way M3 does:
  // the framework's focus WASH stays on `hasFocus` and says "the keyboard is
  // somewhere in here", and the ring says "this is the thing Enter acts on".
  // Exactly one ring is ever on screen.
  final FocusNode _node = FocusNode(debugLabel: 'StateLayer');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    final focused = _node.hasPrimaryFocus;
    if (focused != _focused) setState(() => _focused = focused);
  }

  @override
  void dispose() {
    _node
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final motion = Motion.of(context);
    return Stack(
      // Passthrough, not loose: the child sees the constraints the StateLayer
      // was given, unchanged, and the stack takes the child's size. The overlay
      // is positioned, so it never participates in sizing (rule 1).
      fit: StackFit.passthrough,
      children: [
        Material(
          // The ambient style, restated: a Material otherwise imposes
          // `bodyMedium` on its subtree, and this wrapper must change what a
          // surface LOOKS like at rest by exactly nothing.
          textStyle: DefaultTextStyle.of(context).style,
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onDoubleTap: widget.onDoubleTap,
            borderRadius: widget.borderRadius,
            focusNode: _node,
            // The pointing hand, everywhere something is tappable (#259).
            // `InkWell`'s own default is `adaptiveClickable`, which is the hand
            // on the WEB and the plain arrow on every native platform — so a
            // hand-built surface would disagree with the `ListTile`s the app
            // already ships, which resolve `clickable` and do point.
            mouseCursor: WidgetStateMouseCursor.clickable,
            overlayColor: _stateLayerOverlay(scheme),
            // Reduced motion keeps the press LAYER and drops the spread.
            splashFactory: motion.enabled ? null : NoSplash.splashFactory,
            // The hover and focus layers' own fade — zero under reduced motion.
            hoverDuration: motion.short,
            child: widget.child,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _focused ? 1 : 0,
              duration: motion.short,
              // At zero the ring is not painted at all, so an unfocused
              // surface is byte-identical to one with no ring in the tree.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: widget.borderRadius,
                  border: Border.all(
                    color: scheme.primary,
                    width: _focusRingWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A drag handle's pointer affordance on the desktop (#259).
///
/// A handle is dragged, not tapped, so it gets no ripple, no wash and no ring —
/// the cursor IS its state, and without one the app's two reorder handles were
/// the only grab points on screen that looked like plain text. [MouseRegion]
/// adds no layout, so the handle's 48dp touch box is untouched.
///
/// `grab` rather than `grabbing`: this says the handle CAN be taken. The
/// closed-hand state belongs to the drag itself, which `ReorderableListView`
/// owns and gives no hook to dress.
Widget dragHandleCursor({required Widget child}) =>
    MouseRegion(cursor: SystemMouseCursors.grab, child: child);
