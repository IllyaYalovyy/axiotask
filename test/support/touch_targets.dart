import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Phone orientations exercised by the touch contracts.
enum PhoneOrientation { portrait, landscape }

/// A phone screen described by its short side (the portrait width).
///
/// 320 is the narrowest Android phone width (a 720 × 1440 panel at 2.25 dpr,
/// or display size set to largest); 360 is the narrowest common width; 443 is
/// the Pixel 10 Pro XL used by the 2026-11-15 native audit (1080 px at
/// 2.4375 dpr).
final class PhoneViewport {
  const PhoneViewport(this.shortSide, this.orientation, this.textScale);

  final double shortSide;
  final PhoneOrientation orientation;
  final double textScale;

  double get longSide => switch (shortSide) {
    320 => 640,
    443 => 986,
    _ => 800,
  };

  Size get logicalSize => orientation == PhoneOrientation.portrait
      ? Size(shortSide, longSide)
      : Size(longSide, shortSide);

  String get name =>
      '${shortSide.round()}_${orientation.name}_${textScale.round()}x';

  @override
  String toString() => name;
}

/// Every width, orientation and text scale the phone task-row contracts
/// (Android audit cases 01 and 22) must hold at.
final phoneViewports = List<PhoneViewport>.unmodifiable(<PhoneViewport>[
  for (final shortSide in <double>[360, 443])
    for (final orientation in PhoneOrientation.values)
      for (final textScale in <double>[1, 2])
        PhoneViewport(shortSide, orientation, textScale),
]);

/// Every width, orientation and text scale the phone selection toolbar
/// contract (Android audit case 06) must hold at, from the narrowest phone.
final selectionViewports = List<PhoneViewport>.unmodifiable(<PhoneViewport>[
  for (final shortSide in <double>[320, 360, 443])
    for (final orientation in PhoneOrientation.values)
      for (final textScale in <double>[1, 2])
        PhoneViewport(shortSide, orientation, textScale),
]);

/// Whether a pointer down at [position] is routed to [control]'s own tap
/// handler, as opposed to the row or another control behind or beside it.
bool reachesControl(WidgetTester tester, Finder control, Offset position) {
  final receiver = tester.renderObject(
    find.descendant(of: control, matching: find.byType(InkWell)).first,
  );
  final result = HitTestResult();
  tester.binding.hitTestInView(result, position, tester.view.viewId);
  return result.path.any((entry) => entry.target == receiver);
}

/// Resolution, in logical pixels, of [measureHitRegion]'s edge search.
const hitRegionTolerance = 1 / 256;

/// Measures the screen region whose pointer downs reach [control] by probing
/// real hit tests outward from its centre, rather than reading icon or
/// widget sizes. Each edge is found by bisection to [hitRegionTolerance].
/// The region must be rectangular: points just inside all four corners hit.
Rect measureHitRegion(WidgetTester tester, Finder control) {
  const limit = 160.0;
  final center = tester.getCenter(control);
  expect(
    reachesControl(tester, control, center),
    isTrue,
    reason: 'The centre of $control must reach the control',
  );
  bool hits(Offset direction, double distance) =>
      reachesControl(tester, control, center + direction * distance);
  double reach(Offset direction) {
    var inside = 0.0;
    var outside = 1.0;
    while (hits(direction, outside)) {
      inside = outside;
      outside += 1;
      if (outside > limit) fail('$control hit region exceeds $limit');
    }
    while (outside - inside > hitRegionTolerance / 4) {
      final middle = (inside + outside) / 2;
      if (hits(direction, middle)) {
        inside = middle;
      } else {
        outside = middle;
      }
    }
    return outside;
  }

  final region = Rect.fromLTRB(
    center.dx - reach(const Offset(-1, 0)),
    center.dy - reach(const Offset(0, -1)),
    center.dx + reach(const Offset(1, 0)),
    center.dy + reach(const Offset(0, 1)),
  );
  final inner = region.deflate(hitRegionTolerance);
  for (final corner in <Offset>[
    inner.topLeft,
    inner.topRight,
    inner.bottomLeft,
    inner.bottomRight,
  ]) {
    expect(
      reachesControl(tester, control, corner),
      isTrue,
      reason: 'Hit region $region of $control must include corner $corner',
    );
  }
  return region;
}

/// Asserts [control] is a labelled, tappable button whose touch hit region
/// and accessibility focus area are at least 48 × 48 logical pixels.
Rect expectTouchTarget(
  WidgetTester tester,
  Finder control, {
  required String label,
}) {
  final region = measureHitRegion(tester, control);
  expect(
    region.width,
    greaterThanOrEqualTo(kMinInteractiveDimension - hitRegionTolerance),
    reason: '$label hit region $region is too narrow for touch',
  );
  expect(
    region.height,
    greaterThanOrEqualTo(kMinInteractiveDimension - hitRegionTolerance),
    reason: '$label hit region $region is too short for touch',
  );
  final node = tester.getSemantics(control);
  final data = node.getSemanticsData();
  expect(
    data.hasAction(SemanticsAction.tap),
    isTrue,
    reason: '$label exposes a tap action to assistive technology',
  );
  expect(
    data.flagsCollection.isButton,
    isTrue,
    reason: '$label is announced as a button',
  );
  expect(
    '${data.label}\n${data.tooltip}',
    contains(label),
    reason: 'Assistive technology announces "$label"',
  );
  expect(
    node.rect.width,
    greaterThanOrEqualTo(kMinInteractiveDimension),
    reason: '$label accessibility focus area ${node.rect}',
  );
  expect(
    node.rect.height,
    greaterThanOrEqualTo(kMinInteractiveDimension),
    reason: '$label accessibility focus area ${node.rect}',
  );
  return region;
}

/// Points one logical pixel inside each edge of [region], where a finger
/// that only grazes the control lands.
List<Offset> edgeProbes(Rect region) => <Offset>[
  region.centerLeft + const Offset(1, 0),
  region.centerRight - const Offset(1, 0),
  region.topCenter + const Offset(0, 1),
  region.bottomCenter - const Offset(0, 1),
];

/// Asserts an open popup menu shows every label whole inside the screen and
/// inside the menu's scroll viewport, as an item tall enough to tap, with no
/// word broken or cut off. With [singleLine], labels must also fit on one
/// line. Scrolls each label into view first, as a user would.
Future<void> expectReadableMenu(
  WidgetTester tester,
  List<String> labels, {
  bool singleLine = true,
}) async {
  final screen =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final label in labels) {
    final text = find.text(label);
    expect(text, findsOneWidget, reason: 'Menu offers "$label"');
    await tester.ensureVisible(text);
    await tester.pumpAndSettle();
    expect(
      text.hitTestable(),
      findsOneWidget,
      reason: '"$label" can be reached by touch',
    );
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '"$label" is not truncated',
    );
    expect(
      paragraph.getMinIntrinsicWidth(double.infinity),
      lessThanOrEqualTo(paragraph.size.width + 0.5),
      reason: 'No word of "$label" is broken across lines or cut off',
    );
    if (singleLine) {
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(paragraph.size.width + 0.5),
        reason: '"$label" is laid out whole on one line',
      );
    }
    final rect = tester.getRect(text);
    expect(
      _contains(screen, rect),
      isTrue,
      reason: '"$label" at $rect lies inside the screen $screen',
    );
    final viewport = find.ancestor(of: text, matching: find.byType(Scrollable));
    final visible = tester.getRect(viewport.first);
    expect(
      _contains(visible, rect),
      isTrue,
      reason: '"$label" at $rect is not clipped by the menu at $visible',
    );
    final item = find.ancestor(
      of: text,
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
    );
    final itemRect = tester.getRect(item.first);
    expect(
      itemRect.height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
      reason: '"$label" item is tall enough to tap',
    );
    expect(
      _contains(itemRect, rect),
      isTrue,
      reason: '"$label" fits inside its item $itemRect',
    );
  }
  final menuWidth = tester
      .getSize(
        find
            .ancestor(
              of: find.text(labels.first),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .width;
  expect(
    menuWidth,
    greaterThanOrEqualTo(112),
    reason: 'Material menus are at least 112 logical pixels wide',
  );
}

bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

/// Font family registered by [loadAndroidTextFont].
const androidTextFontFamily = 'TouchContractRoboto';

/// Registers the locked Flutter SDK's Roboto, Android's system font, so
/// host widget tests measure text the way the device does instead of with
/// the square test glyphs.
Future<void> loadAndroidTextFont() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document =
      jsonDecode(await packageConfig.readAsString()) as Map<String, Object?>;
  final flutter = (document['packages']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((value) => value['name'] == 'flutter');
  final flutterPackage = Directory.fromUri(
    packageConfig.absolute.uri.resolve(flutter['rootUri']! as String),
  );
  final font = File(
    '${flutterPackage.parent.parent.path}'
    '/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!font.existsSync()) {
    throw StateError('The locked Flutter SDK Roboto font is unavailable.');
  }
  final bytes = await font.readAsBytes();
  await (FontLoader(androidTextFontFamily)..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
}
