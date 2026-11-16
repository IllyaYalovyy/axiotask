import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'touch_targets.dart';

/// One control of the bulk-selection toolbar and the name assistive
/// technology must announce for it.
typedef SelectionControl = ({String key, String label});

const completeSelectionControl = (key: 'bulk-complete-open', label: 'Complete');
const rescheduleSelectionControl = (
  key: 'bulk-reschedule-open',
  label: 'Reschedule',
);
const moveSelectionControl = (key: 'bulk-move-open', label: 'Move');
const deleteSelectionControl = (key: 'bulk-delete-open', label: 'Delete');
const exitSelectionControl = (
  key: 'bulk-selection-close',
  label: 'Exit task selection',
);

/// Every control Android audit case 06 requires on a phone, in order.
const selectionControls = <SelectionControl>[
  completeSelectionControl,
  rescheduleSelectionControl,
  moveSelectionControl,
  deleteSelectionControl,
  exitSelectionControl,
];

Finder selectionControlFinder(SelectionControl control) =>
    find.byKey(Key(control.key));

/// Asserts the selection toolbar fits the screen, shows "[count] selected"
/// whole, and that every [selectionControls] entry is a labelled touch
/// target of at least 48 × 48 whose real hit region lies on screen and does
/// not overlap another control. Returns each control's measured hit region.
Map<SelectionControl, Rect> expectSelectionToolbarReachable(
  WidgetTester tester, {
  required int count,
  required String reason,
}) {
  expect(
    tester.takeException(),
    isNull,
    reason: '$reason: the selection toolbar lays out without overflow',
  );
  final screen =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  final bar = find.byKey(const Key('bulk-action-bar'));
  expect(bar, findsOneWidget, reason: '$reason: selection mode is active');
  final barRect = tester.getRect(bar);
  expect(
    _contains(screen, barRect),
    isTrue,
    reason: '$reason: toolbar $barRect lies inside the screen $screen',
  );

  final countText = find.descendant(
    of: bar,
    matching: find.text('$count selected'),
  );
  expect(
    countText.hitTestable(),
    findsOneWidget,
    reason: '$reason: "$count selected" is visible',
  );
  final paragraph = tester.renderObject<RenderParagraph>(countText);
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '$reason: the selection count is not truncated',
  );
  expect(
    _contains(barRect, tester.getRect(countText)),
    isTrue,
    reason: '$reason: the selection count lies inside the toolbar',
  );

  final regions = <SelectionControl, Rect>{};
  for (final control in selectionControls) {
    final finder = selectionControlFinder(control);
    expect(finder, findsOneWidget, reason: '$reason: ${control.label}');
    final region = expectTouchTarget(tester, finder, label: control.label);
    expect(
      _contains(screen, region),
      isTrue,
      reason: '$reason: ${control.label} hit region $region is on screen',
    );
    final visible = tester.getRect(finder);
    expect(
      _contains(barRect, visible),
      isTrue,
      reason: '$reason: ${control.label} at $visible is inside the toolbar',
    );
    regions[control] = region;
  }
  for (final (index, control) in selectionControls.indexed) {
    for (final other in selectionControls.skip(index + 1)) {
      // Adjacent targets may touch; the bisection tolerance is not overlap.
      expect(
        regions[control]!
            .deflate(hitRegionTolerance)
            .overlaps(regions[other]!.deflate(hitRegionTolerance)),
        isFalse,
        reason:
            '$reason: ${control.label} ${regions[control]} overlaps '
            '${other.label} ${regions[other]}',
      );
    }
    for (final probe in edgeProbes(regions[control]!)) {
      for (final other in selectionControls) {
        if (other == control) continue;
        expect(
          reachesControl(tester, selectionControlFinder(other), probe),
          isFalse,
          reason:
              '$reason: an edge tap on ${control.label} at $probe must not '
              'reach ${other.label}',
        );
      }
    }
  }
  return regions;
}

/// Taps [control] where a finger lands, at the centre of its measured hit
/// region, after checking the pointer is routed to that control.
Future<void> tapSelectionControl(
  WidgetTester tester,
  SelectionControl control,
) async {
  final finder = selectionControlFinder(control);
  final region = measureHitRegion(tester, finder);
  expect(reachesControl(tester, finder, region.center), isTrue);
  await tester.tapAt(region.center);
}

bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;
