// #247 — the app's MEASURED contrast contract, in both themes.
//
// The failure this bars is a whole class, not one bug: a Material default (or
// a future tweak to one) that renders a control or a piece of content the user
// cannot see. `ColorScheme.fromSeed` is generous with its `on*` text roles and
// careless with everything else — the M3 `outlineVariant` divider lands at
// 1.6:1 on the light page, the `primaryContainer` FAB at 1.2:1 — and none of
// that is visible in a golden diff or a `!=` assertion.
//
// So every surface named here is measured against the WCAG bar that actually
// applies to it:
//
//   • [_aaText] 4.5:1 — WCAG 1.4.3 AA, normal-size text. The row's metadata
//     line, the badge labels, a COMPLETED task's title (content, not an
//     inactive control, so the "incidental text" exemption does not apply).
//   • [_nonText] 3:1 — WCAG 1.4.11, user-interface components and graphics
//     needed to understand the content: the checkbox outline, the FAB's own
//     shape against the page, the dividers that separate a menu's destructive
//     action or the sidebar's views from its lists, the icon badges, the
//     subtask progress bar's fill.
//
// Genuinely disabled controls (the bulk bar with nothing selected, a greyed
// toolbar entry) are exempt by 1.4.3/1.4.11 and are deliberately not asserted.
//
// Every number here is read from what the widget ACTUALLY PAINTS — the resolved
// style on the rendered paragraph, the `Material` fill the FAB builds, the
// `BorderSide` `Divider` resolves, the `BoxDecoration` the row washes with —
// never from the constant a helper returns, so a widget that stops consulting
// the theme fails exactly like a theme with the wrong colour in it.

import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/new_task_fab.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/color_metrics.dart';

/// WCAG 1.4.3 AA for normal-size text.
const _aaText = 4.5;

/// WCAG 1.4.11 for user-interface components and meaningful graphics.
const _nonText = 3.0;

/// The WCAG ratio of [fg] as it is actually SEEN on [background].
///
/// A colour with alpha has no luminance of its own until it is composited, so
/// it is composited first: the 38%-black completed title this task replaces
/// measures 21:1 raw (i.e. "pure black") and 2.3:1 as the user sees it.
double _ratioOn(Color fg, Color background) =>
    contrastRatio(Color.alphaBlend(fg, background), background);

/// A fixed "today" so the due labels below are deterministic.
final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

final _themes = {'light': buildLightTheme(), 'dark': buildDarkTheme()};

/// The colour that actually reaches the glyphs of [text] (or of an icon, which
/// Material also renders as a paragraph).
Color _glyphColor(WidgetTester tester, Finder of) {
  final rich = tester.widget<RichText>(
    find.descendant(of: of, matching: find.byType(RichText)),
  );
  return rich.text.style!.color!;
}

Color _textColor(WidgetTester tester, String text) =>
    _glyphColor(tester, find.text(text));

/// Every full-row wash the [TaskRow] paints, composited over the page — i.e.
/// the background its text is really read against. Restricted to the boxes that
/// WRAP the row's content (ancestors of the checkbox column) so the list tag's
/// own pill, which is inside the row, is not mistaken for a row background.
Color _rowBackground(WidgetTester tester, ColorScheme scheme) {
  var background = scheme.surface;
  final washes = tester
      .widgetList<DecoratedBox>(
        find.ancestor(
          of: find.byKey(const Key('row-checkbox-target')),
          matching: find.byType(DecoratedBox),
        ),
      )
      .map((b) => b.decoration)
      .whereType<BoxDecoration>()
      .map((d) => d.color)
      .whereType<Color>()
      .where((c) => c.a > 0)
      .toList()
      // Outermost first: a wash is composited over the page, then anything
      // painted inside it over that.
      .reversed;
  for (final wash in washes) {
    background = Color.alphaBlend(wash, background);
  }
  return background;
}

/// The row every metadata assertion runs against: notes (so the notes badge and
/// two link badges render), a due date, subtask progress and a list tag.
Future<void> _pumpRow(
  WidgetTester tester, {
  required ThemeData theme,
  bool completed = false,
  bool selected = false,
  bool openInDetail = false,
}) async {
  await withClock(_clock, () async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: TaskRow(
            title: 'Book the dentist',
            notes: 'see https://a.test/x and https://b.test/y',
            completed: completed,
            due: '2026-06-15T00:00:00.000Z',
            subtaskDone: 2,
            subtaskTotal: 5,
            listTag: 'Groceries',
            selected: selected,
            openInDetail: openInDetail,
            onOpenUrl: (_) {},
            onOpen: () {},
            onToggle: () {},
            onRename: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  });
}

/// The alpha every ancestor [Opacity] multiplies onto what [of] paints. A row
/// held at 50% opacity is 50% opacity to the eye no matter what colour its
/// style names, so contrast has to be measured through it.
double _ancestorOpacity(WidgetTester tester, Finder of) {
  var alpha = 1.0;
  for (final o in tester.widgetList<Opacity>(
    find.ancestor(of: of, matching: find.byType(Opacity)),
  )) {
    alpha *= o.opacity;
  }
  return alpha;
}

/// The drawer's list section with one EXCLUDED list, under [theme].
Future<void> _pumpSidebar(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Row(
          children: [
            Sidebar(
              selectedViewId: 'all',
              counts: const {'L1': 4},
              lists: const [
                StoredTaskList(
                  list: TaskList(
                    id: 'L1',
                    title: 'Work',
                    etag: 'e',
                    updated: 't',
                  ),
                  syncState: SyncState.clean,
                  localUpdated: 't',
                ),
              ],
              excludedLists: const {'L1'},
              onSelectView: (_) {},
              onCreateList: (_, {localOnly = false}) {},
              onRenameList: (_, _) {},
              onDeleteList: (_) {},
              onToggleExclude: (_) {},
              onReorderLists: (_) {},
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final entry in _themes.entries) {
    final name = entry.key;
    final theme = entry.value;
    final scheme = theme.colorScheme;

    group('$name theme:', () {
      // ── Dividers ──────────────────────────────────────────────────────────
      // Not decoration: the app's dividers carry structure the content depends
      // on — the rule that fences the detail overflow's Delete off from the
      // safe actions (#246), the one between the sidebar's smart views and its
      // lists, the section rules in Properties. M3's `outlineVariant` default
      // is 1.6:1 / 2.0:1 — a line a low-vision user simply does not see.
      testWidgets('a divider is visible on every surface it lands on', (
        tester,
      ) async {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (c) {
                context = c;
                return const Scaffold(body: Divider());
              },
            ),
          ),
        );
        // The colour Divider/VerticalDivider/PopupMenuDivider all resolve.
        final line = Divider.createBorderSide(context).color;
        final surfaces = {
          'the page': scheme.surface,
          'a menu / sheet': scheme.surfaceContainer,
          'the composer sheet': scheme.surfaceContainerLow,
          'a raised container': scheme.surfaceContainerHigh,
          'the highest container': scheme.surfaceContainerHighest,
        };
        for (final surface in surfaces.entries) {
          expect(
            _ratioOn(line, surface.value),
            greaterThanOrEqualTo(_nonText),
            reason: '$name: the divider disappears into ${surface.key}',
          );
        }
      });

      // ── The FAB ───────────────────────────────────────────────────────────
      // The phone's ONE creation affordance. M3 seeds it `primaryContainer`,
      // which sits 1.2:1 from the light page: a 56dp blob whose edge cannot be
      // made out at all, identifiable only by the glyph inside it.
      testWidgets('the FAB is a shape you can see, with a legible glyph', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(body: NewTaskFab(visible: true, onPressed: () {})),
          ),
        );
        await tester.pump();

        final fill = tester
            .widget<Material>(
              find.descendant(
                of: find.byType(FloatingActionButton),
                matching: find.byType(Material),
              ),
            )
            .color!;
        expect(
          _ratioOn(fill, scheme.surface),
          greaterThanOrEqualTo(_nonText),
          reason: '$name: the FAB has no visible edge against the page',
        );
        expect(
          _ratioOn(_glyphColor(tester, find.byIcon(Icons.add)), fill),
          greaterThanOrEqualTo(_aaText),
          reason: '$name: the FAB\'s "+" is lost in the FAB',
        );
      });

      // ── The row: meta text, badges, checkbox, on every background ─────────
      // The row is the app's densest surface AND the one that changes colour
      // underneath its own text: a wash deep enough to be seen is a wash that
      // can swallow the 13px metadata sitting on it. Each case re-reads the
      // background the row actually paints and measures against THAT.
      final backgrounds = {
        'the bare page': (selected: false, openInDetail: false),
        'the open-in-detail wash': (selected: false, openInDetail: true),
        'the multi-select wash': (selected: true, openInDetail: false),
      };
      for (final background in backgrounds.entries) {
        testWidgets('the row stays legible on ${background.key}', (
          tester,
        ) async {
          await _pumpRow(
            tester,
            theme: theme,
            selected: background.value.selected,
            openInDetail: background.value.openInDetail,
          );
          final page = _rowBackground(tester, scheme);

          // Metadata text (WCAG 1.4.3): the due label, the subtask count, the
          // link badge's "+N" — and the list label, which since #276 is plain
          // trailing text on the title line. It used to carry its own opaque
          // pill and was measured against THAT; with the pill gone it has to
          // clear the bar on whatever the row itself is painting, wash
          // included, like every other quiet label in the row.
          for (final label in ['today', '2/5', '+1', 'Groceries']) {
            expect(
              _ratioOn(_textColor(tester, label), page),
              greaterThanOrEqualTo(_aaText),
              reason: '$name: "$label" is unreadable on ${background.key}',
            );
          }

          // Icon badges and the progress bar (WCAG 1.4.11).
          expect(
            _ratioOn(
              tester.widget<Icon>(find.byIcon(Icons.notes)).color!,
              page,
            ),
            greaterThanOrEqualTo(_nonText),
            reason: '$name: the notes badge vanishes on ${background.key}',
          );
          expect(
            _ratioOn(
              tester.widget<Icon>(find.byIcon(Icons.open_in_new)).color!,
              page,
            ),
            greaterThanOrEqualTo(_nonText),
            reason: '$name: the link badge vanishes on ${background.key}',
          );
          final bar = tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
          expect(
            _ratioOn(bar.color!, bar.backgroundColor!),
            greaterThanOrEqualTo(_nonText),
            reason: '$name: the subtask progress reads as an empty bar',
          );
          expect(
            _ratioOn(bar.color!, page),
            greaterThanOrEqualTo(_nonText),
            reason: '$name: the subtask progress vanishes on ${background.key}',
          );

          // The unchecked checkbox: its 2dp outline is the ONLY thing that says
          // a tickable box is there. Read from the theme the row's own checkbox
          // inherits, which is the side the framework paints.
          final side = CheckboxTheme.of(
            tester.element(find.byType(Checkbox)),
          ).side;
          expect(
            side,
            isNotNull,
            reason:
                '$name: the checkbox outline is an unowned Material default — '
                'pin it so its contrast is this app\'s contract',
          );
          final outline = WidgetStateProperty.resolveAs<BorderSide?>(
            side!,
            <WidgetState>{},
          )!.color;
          expect(
            _ratioOn(outline, page),
            greaterThanOrEqualTo(_nonText),
            reason:
                '$name: an unchecked checkbox is invisible on ${background.key}',
          );
        });
      }

      // Non-happy path: a COMPLETED task, which the row deliberately dims. It
      // is still content — tappable, un-completable, and shown by choice
      // ("Show completed") — so the 1.4.3 exemption for inactive controls does
      // not cover it. `ThemeData.disabledColor` put it at 2.3:1 / 3.0:1.
      testWidgets('a completed task\'s title is dimmed but still readable', (
        tester,
      ) async {
        await _pumpRow(tester, theme: theme, completed: true);
        final title = _textColor(tester, 'Book the dentist');
        expect(
          _ratioOn(title, scheme.surface),
          greaterThanOrEqualTo(_aaText),
          reason: '$name: a completed task\'s title cannot be read',
        );
        expect(
          _ratioOn(title, scheme.surface),
          lessThan(_ratioOn(scheme.onSurface, scheme.surface)),
          reason:
              '$name: a completed title must still read QUIETER than an open '
              'one — legible is not the same as undimmed',
        );
      });

      // ── The drawer's excluded list (#248) ─────────────────────────────────
      // Non-happy path: a list the user took OUT of the smart views. It is not
      // a disabled control — it opens, renames, reorders and deletes like any
      // other — so 1.4.3 applies in full. Held at 50% opacity it measured 2.3:1
      // and the italic bought nothing; the `visibility_off` glyph now carries
      // the meaning and has to be seen (1.4.11) for that to be true.
      testWidgets('an excluded list is quieter but still legible', (
        tester,
      ) async {
        await _pumpSidebar(tester, theme);

        final title = find.text('Work');
        final titleColor = _glyphColor(tester, title).withValues(
          alpha: _glyphColor(tester, title).a * _ancestorOpacity(tester, title),
        );
        expect(
          _ratioOn(titleColor, scheme.surface),
          greaterThanOrEqualTo(_aaText),
          reason: '$name: an excluded list\'s name cannot be read',
        );
        expect(
          _ratioOn(titleColor, scheme.surface),
          lessThan(_ratioOn(scheme.onSurface, scheme.surface)),
          reason:
              '$name: an excluded list must still read QUIETER than an '
              'included one',
        );

        final glyph = find.byIcon(Icons.visibility_off_outlined);
        final glyphColor = _glyphColor(tester, glyph).withValues(
          alpha: _glyphColor(tester, glyph).a * _ancestorOpacity(tester, glyph),
        );
        expect(
          _ratioOn(glyphColor, scheme.surface),
          greaterThanOrEqualTo(_nonText),
          reason:
              '$name: the exclusion glyph — the only thing that says WHY the '
              'row is quiet — vanishes into the drawer',
        );
      });

      // ── The washes themselves ─────────────────────────────────────────────
      // Both are supporting tints, and the multi-select state additionally
      // carries the `primary` accent bar that is its ≥3:1 indicator. What they
      // must not be is invisible, or each other.
      test('the two selection washes are perceptible and distinct', () {
        final open = Color.alphaBlend(openDetailWash(scheme), scheme.surface);
        final selected = Color.alphaBlend(
          multiSelectWash(scheme),
          scheme.surface,
        );
        expect(
          perceptualDistance(open, scheme.surface),
          greaterThanOrEqualTo(4.0),
          reason: '$name: the open-in-detail row does not read as picked out',
        );
        expect(
          perceptualDistance(selected, scheme.surface),
          greaterThanOrEqualTo(4.0),
          reason: '$name: a multi-selected row does not read as selected',
        );
        expect(
          perceptualDistance(open, selected),
          greaterThan(2.3),
          reason:
              '$name: "showing in the detail" and "picked for a bulk op" are '
              'the same colour to the eye',
        );
        expect(
          _ratioOn(scheme.primary, scheme.surface),
          greaterThanOrEqualTo(_nonText),
          reason:
              '$name: the accent bar is the multi-select state\'s own 3:1 '
              'indicator — it may not fade into the page',
        );
      });
    });
  }
}
