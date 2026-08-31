// The compact shell's bottom navigation bar — hand-rolled (#237).
//
// This is the M3 navigation bar drawn out of framework primitives (Material
// surface + Tooltip + InkResponse + the public [NavigationIndicator] + our own
// [Semantics]), the way the shell already owns the rest of its chrome. It
// exists because Material's own `NavigationBar` cannot say "nothing here is
// selected":
//
//   • it asserts `0 <= selectedIndex < destinations.length` — there is no
//     "no destination" index (unlike NavigationRail, whose index is nullable),
//     so the shell had to point a SENTINEL index at a destination, and
//   • it hardcodes `Semantics(role: tab, selected: i == selectedIndex)` as an
//     ANCESTOR of everything a caller can supply, merged, so no wrapping
//     `Semantics(selected: false)` can clear the flag (merged flags OR).
//
// #236 could hide the sentinel's PIXELS (no pill, no filled icon); it could not
// touch the announcement, so TalkBack kept saying "Focus, tab, selected" while
// the user sat in a list opened from the drawer. Here [selectedIndex] is simply
// nullable: null means every destination is unselected, in the pixels and in
// the semantics alike, with no sentinel anywhere.
//
// What we take on in exchange is the M3 geometry, which is reproduced from the
// spec the framework encodes: an 80dp surfaceContainer surface at elevation 3,
// destinations sharing the width equally (each therefore far past the 48dp
// touch floor), a 64×32 stadium indicator scaling in behind the icon over
// 500ms, the icon swapping to its filled variant as the selection animation
// turns forward, and the label pinned directly under the icon with the pair
// centred as a group — label text scaling clamped to 1.3 so an enlarged system
// font cannot swallow the bar.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;

import 'motion.dart';

/// A single navigation destination for the shell (rail + bar share this data).
class ShellDestination {
  const ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  /// Icon shown when the destination is not selected.
  final IconData icon;

  /// Icon shown when the destination is selected.
  final IconData selectedIcon;

  /// The destination label (nav text).
  final String label;
}

/// The compact bottom bar. [selectedIndex] is `null` when the active view is
/// NOT one of [destinations] — a list opened from the drawer — and then no
/// destination renders or announces as selected.
class ShellNavBar extends StatelessWidget {
  const ShellNavBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  });

  final List<ShellDestination> destinations;

  /// The selected destination, or `null` for an out-of-set view (#236/#237).
  final int? selectedIndex;

  final ValueChanged<int> onDestinationSelected;

  /// M3 navigation-bar height.
  static const double height = 80;

  /// How long a destination takes to go from unselected to selected — the
  /// framework bar's own span ([MotionDurations.navSelection]), so the
  /// transition feels unchanged.
  static const Duration selectionDuration = MotionDurations.navSelection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barTheme = NavigationBarTheme.of(context);
    return Material(
      color: barTheme.backgroundColor ?? theme.colorScheme.surfaceContainer,
      elevation: barTheme.elevation ?? 3,
      shadowColor: barTheme.shadowColor ?? Colors.transparent,
      surfaceTintColor: barTheme.surfaceTintColor ?? Colors.transparent,
      child: SafeArea(
        // One container for the strip, so a screen reader reads five tabs of a
        // single tab bar rather than five loose buttons. `explicitChildNodes`
        // keeps each destination its own node under it.
        child: Semantics(
          role: SemanticsRole.tabBar,
          explicitChildNodes: true,
          container: true,
          child: SizedBox(
            height: barTheme.height ?? height,
            child: Row(
              children: <Widget>[
                for (var i = 0; i < destinations.length; i++)
                  Expanded(
                    child: _Destination(
                      destination: destinations[i],
                      index: i,
                      total: destinations.length,
                      selected: i == selectedIndex,
                      onTap: () => onDestinationSelected(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One destination: the indicator pill, the icon, the label, the touch target
/// and the tab semantics. Stateful for the selection animation it owns.
class _Destination extends StatefulWidget {
  const _Destination({
    required this.destination,
    required this.index,
    required this.total,
    required this.selected,
    required this.onTap,
  });

  final ShellDestination destination;
  final int index;
  final int total;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Destination> createState() => _DestinationState();
}

class _DestinationState extends State<_Destination>
    with SingleTickerProviderStateMixin {
  /// 0 = unselected, 1 = selected. Drives the pill, the icon variant and the
  /// label style together, so they can never disagree.
  late final AnimationController _selection = AnimationController(
    vsync: this,
    duration: ShellNavBar.selectionDuration,
    value: widget.selected ? 1 : 0,
  );

  /// Marks the icon subtree so the ink splash can be confined to the pill
  /// rather than washing over the whole 80dp cell.
  final GlobalKey _iconKey = GlobalKey();

  /// Owned per destination: a [MultiChildLayoutDelegate] keys its children by
  /// id while it lays out, so instances are not shared between cells.
  final _DestinationLayout _layout = _DestinationLayout();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" (Android) / reduced motion: the pill and the icon
    // still change, they just arrive instead of growing.
    _selection.duration = Motion.of(
      context,
    ).resolve(ShellNavBar.selectionDuration);
  }

  @override
  void didUpdateWidget(_Destination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      if (widget.selected) {
        _selection.forward();
      } else {
        _selection.reverse();
      }
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final barTheme = NavigationBarTheme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final shape = barTheme.indicatorShape ?? const StadiumBorder();

    return MergeSemantics(
      child: Semantics(
        role: SemanticsRole.tab,
        // The whole point of the hand-roll: an unselected destination says so,
        // and with no destination selected all five say so.
        selected: widget.selected,
        button: true,
        child: Tooltip(
          message: widget.destination.label,
          verticalOffset: 42,
          excludeFromSemantics: true,
          preferBelow: false,
          child: _IndicatorInkWell(
            iconKey: _iconKey,
            customBorder: shape,
            overlayColor: barTheme.overlayColor,
            onTap: widget.onTap,
            child: CustomMultiChildLayout(
              delegate: _layout,
              children: <Widget>[
                LayoutId(
                  id: _DestinationLayout.iconId,
                  child: KeyedSubtree(
                    key: _iconKey,
                    child: _icon(colors, barTheme, shape),
                  ),
                ),
                LayoutId(
                  id: _DestinationLayout.labelId,
                  child: _label(theme, colors, barTheme, localizations),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The indicator pill with the icon on top. The icon swaps to its filled
  /// variant the moment the selection animation turns forward, so the fill and
  /// the growing pill read as one movement.
  Widget _icon(
    ColorScheme colors,
    NavigationBarThemeData barTheme,
    ShapeBorder shape,
  ) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        NavigationIndicator(
          animation: _selection,
          color: barTheme.indicatorColor ?? colors.secondaryContainer,
          shape: shape,
        ),
        _OnSelectionStatus(
          animation: _selection,
          builder: (context) {
            final on = _selection.isForwardOrCompleted;
            final iconTheme =
                barTheme.iconTheme?.resolve(
                  on ? const {WidgetState.selected} : const <WidgetState>{},
                ) ??
                IconThemeData(
                  size: 24,
                  color: on
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                );
            return IconTheme.merge(
              data: iconTheme,
              child: Icon(
                on ? widget.destination.selectedIcon : widget.destination.icon,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _label(
    ThemeData theme,
    ColorScheme colors,
    NavigationBarThemeData barTheme,
    MaterialLocalizations localizations,
  ) {
    return Padding(
      padding: barTheme.labelPadding ?? const EdgeInsets.only(top: 4),
      child: _OnSelectionStatus(
        animation: _selection,
        builder: (context) {
          final on = _selection.isForwardOrCompleted;
          final style =
              barTheme.labelTextStyle?.resolve(
                on ? const {WidgetState.selected} : const <WidgetState>{},
              ) ??
              theme.textTheme.labelMedium?.apply(
                color: on ? colors.onSurface : colors.onSurfaceVariant,
              );
          return MediaQuery.withClampedTextScaling(
            // Past 1.3 the labels stop being labels and start being the bar;
            // clamping keeps the visual hierarchy at any system font size.
            maxScaleFactor: 1.3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(widget.destination.label, style: style),
                // Zero-sized, and read out right after the label it follows:
                // "Focus, Tab 1 of 5". Merged into the destination's tab node.
                Semantics(
                  label: localizations.tabLabel(
                    tabIndex: widget.index + 1,
                    tabCount: widget.total,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// [InkResponse] whose splash is clipped to the indicator pill instead of the
/// full-width cell — the M3 press treatment for a nav destination.
class _IndicatorInkWell extends InkResponse {
  const _IndicatorInkWell({
    required this.iconKey,
    super.overlayColor,
    super.customBorder,
    super.onTap,
    super.child,
  }) : super(containedInkWell: true, highlightColor: Colors.transparent);

  final GlobalKey iconKey;

  @override
  RectCallback? getRectCallback(RenderBox referenceBox) {
    return () {
      final iconBox = iconKey.currentContext!.findRenderObject()! as RenderBox;
      final Rect iconRect = iconBox.localToGlobal(Offset.zero) & iconBox.size;
      return referenceBox.globalToLocal(iconRect.topLeft) & iconBox.size;
    };
  }
}

/// Icon over label, the pair centred in the cell as a group.
///
/// A [CustomMultiChildLayout] rather than a [Column] on purpose: it places its
/// children at computed offsets and never reports an overflow, so an enlarged
/// system font spills a label past the bar edge (as the framework bar does)
/// instead of failing the frame with a RenderFlex overflow.
class _DestinationLayout extends MultiChildLayoutDelegate {
  static const int iconId = 1;
  static const int labelId = 2;

  @override
  void performLayout(Size size) {
    final Size iconSize = layoutChild(iconId, BoxConstraints.loose(size));
    final Size labelSize = layoutChild(labelId, BoxConstraints.loose(size));

    final double top = (size.height - iconSize.height - labelSize.height) / 2;
    positionChild(iconId, Offset((size.width - iconSize.width) / 2, top));
    positionChild(
      labelId,
      Offset((size.width - labelSize.width) / 2, top + iconSize.height),
    );
  }

  @override
  bool shouldRelayout(_DestinationLayout oldDelegate) => false;
}

/// Rebuilds only when the selection animation changes DIRECTION — the icon
/// variant and the label style are a step function of it, not a per-frame one.
class _OnSelectionStatus extends StatusTransitionWidget {
  const _OnSelectionStatus({required super.animation, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => builder(context);
}
