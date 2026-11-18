import 'package:material_ui/material_ui.dart';

import '../../../domain/policy/smart_views.dart';

/// The icon of [view] in navigation; [selected] picks the filled variant.
IconData smartViewIcon(SmartView view, {bool selected = false}) =>
    switch (view) {
      SmartView.focus =>
        selected
            ? Icons.center_focus_strong
            : Icons.center_focus_strong_outlined,
      SmartView.upcoming =>
        selected ? Icons.calendar_month : Icons.calendar_month_outlined,
      SmartView.missed => selected ? Icons.history : Icons.history_outlined,
      SmartView.unscheduled =>
        selected ? Icons.event_busy : Icons.event_busy_outlined,
      SmartView.all => selected ? Icons.all_inbox : Icons.all_inbox_outlined,
    };

/// The phone's bottom smart-view navigation, as in v1.5.3: one destination
/// per smart view, sharing the width equally.
///
/// [selected] is null while a list opened from the drawer is shown; then no
/// destination looks or announces itself as selected (Material's
/// `NavigationBar` cannot express that, so the bar is composed here).
/// Each destination announces its view count. Label text scaling is clamped
/// to 1.3 so enlarged system text cannot swallow the bar, and labels scale
/// down rather than overflow at the narrowest widths. On short (landscape)
/// layouts the bar is 56 tall with the label beside the icon.
final class SmartViewNavigationBar extends StatelessWidget {
  const SmartViewNavigationBar({
    required this.selected,
    required this.counts,
    required this.onSelected,
    super.key,
  });

  final SmartView? selected;
  final Map<SmartView, int> counts;
  final ValueChanged<SmartView> onSelected;

  static const double height = 80;
  static const double compactHeight = 56;

  /// Below this available height (phones in landscape) the bar is compact.
  static const double compactBelowHeight = 480;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).height < compactBelowHeight;

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    return Material(
      key: const Key('smart-view-bar'),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: 'Smart views',
            child: SizedBox(
              height: compact ? compactHeight : height,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final view in SmartView.values)
                    Expanded(
                      child: _Destination(
                        view: view,
                        count: counts[view] ?? 0,
                        selected: view == selected,
                        compact: compact,
                        onTap: () => onSelected(view),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _Destination extends StatelessWidget {
  const _Destination({
    required this.view,
    required this.count,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final SmartView view;
  final int count;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final countPhrase = '$count ${count == 1 ? 'task' : 'tasks'}';
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    );
    final indicator = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: compact ? 48 : 64,
      height: compact ? 28 : 32,
      decoration: BoxDecoration(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        smartViewIcon(view, selected: selected),
        size: 24,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
    );
    final label = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(view.title, maxLines: 1, style: labelStyle),
    );
    return Semantics(
      key: Key('smart-view-destination-${view.name}'),
      container: true,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '${view.title}, $countPhrase',
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: '${view.title} · $countPhrase',
        excludeFromSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: compact
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      indicator,
                      const SizedBox(width: 4),
                      Flexible(child: label),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      indicator,
                      const SizedBox(height: 4),
                      label,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
