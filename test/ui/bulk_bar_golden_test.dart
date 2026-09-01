// #265 golden: the bulk bar is ONE row.
//
// The widget tests pin the arithmetic — the slot is [BulkBar.height] at 1.0,
// 1.3 and 2.0 text, every action is hit-testable, the labels drop when they no
// longer fit. Only a picture answers the question the change was actually
// about: does one row of × · count · four actions · "⋮" read as a toolbar the
// way three runs of labelled buttons never did, is the destructive Delete still
// the one thing that stands out, and does the icon-only phone form stay legible
// as a row of actions rather than a strip of glyphs?
//
// This is a NEW baseline created with the change (issue #265), not a
// regeneration of an existing one: no golden had a selection active, which is
// exactly why the 890 green ui goldens never showed the wrap eating the list.
// It was red-checked against the wrap it replaces — generated on the OLD bar
// first, so the diff against these bytes is the change itself.
//
// Determinism: [BulkBar] is rendered directly with static callbacks. It reads
// no clock, holds no timer, has nothing focused or hovered, and its quick-date
// menu is closed (a [MenuAnchor] costs nothing until it opens).

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';

/// The bar at [size], with a strip of list surface under it — the room it
/// leaves is as much the point as the row itself.
Widget _bar(
  ThemeData theme,
  Size size, {
  int count = 3,
  TextScaler textScaler = TextScaler.noScaling,
  TargetPlatform platform = TargetPlatform.android,
}) => MediaQuery(
  // A fixed MediaQuery for the same reason the #258 golden pins one: alchemist
  // resizes the surface after `pumpBeforeTest` and pumps another frame, and
  // nothing in this subtree should change when it does.
  data: MediaQueryData(size: size, textScaler: textScaler),
  child: Theme(
    data: theme.copyWith(platform: platform),
    child: Builder(
      builder: (context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BulkBar(
              count: count,
              onComplete: () {},
              onSetDue: (_) {},
              onPickDue: () {},
              onMove: () {},
              onDuplicate: () {},
              onDemote: () {},
              onDelete: () {},
              onClear: () {},
            ),
            const Divider(height: 1),
            const ListTile(
              title: Text('Draft the migration plan'),
              subtitle: Text('My Tasks'),
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  const phone = Size(400, 160);
  const wide = Size(760, 160);
  // The same phone with room for the sample row BELOW the bar to double in
  // height too: it is the list row that grows at 2.0x, never the bar.
  const phoneLarge = Size(400, 220);

  goldenTest(
    'bulk bar — one row on a phone, on a wide pane, and at 2.0x text',
    fileName: 'bulk_bar_one_row',
    builder: () => GoldenTestGroup(
      columns: 1,
      children: [
        // The phone: no room for four labels, so four icons — and the list
        // starts one row down, not four.
        GoldenTestScenario(
          name: 'phone 400dp — icon actions',
          constraints: BoxConstraints.tight(phone),
          child: _bar(buildLightTheme(), phone),
        ),
        // A wide pane: the SAME row, the same height, the same order, spelled
        // out. Nothing about the geometry changed — only the labels.
        GoldenTestScenario(
          name: 'wide 760dp — the same row, spelled out',
          constraints: BoxConstraints.tight(wide),
          child: _bar(buildLightTheme(), wide, platform: TargetPlatform.linux),
        ),
        // The accessibility ceiling. The count text grows, the row does not:
        // this is the scale at which the wrap reached 340dp.
        GoldenTestScenario(
          name: 'phone 400dp at 2.0x text — still one row',
          constraints: BoxConstraints.tight(phoneLarge),
          child: _bar(
            buildLightTheme(),
            phoneLarge,
            textScaler: const TextScaler.linear(2),
          ),
        ),
        // Dark: the secondary container the bar sits on and the error tint
        // Delete carries are both theme-resolved, so both brightnesses pin.
        GoldenTestScenario(
          name: 'phone 400dp dark',
          constraints: BoxConstraints.tight(phone),
          child: _bar(buildDarkTheme(), phone),
        ),
        // Nothing selected (the toolbar's "Select tasks"): the mode is named,
        // every action reads inert, and Delete has no destructive tint to
        // carry — the control for the light scenario above it.
        GoldenTestScenario(
          name: 'phone 400dp — mode entered, nothing selected yet',
          constraints: BoxConstraints.tight(phone),
          child: _bar(buildLightTheme(), phone, count: 0),
        ),
      ],
    ),
  );
}
