// #260 goldens — the five designed empty states, light and dark.
//
// NEW baselines by intent: before #260 an empty view was a single grey line of
// body text, and these images are the record of what replaced it. They pin the
// three things a screenshot can hold and a widget test cannot: that each view's
// icon is the RIGHT glyph at the right weight above its line, that the block
// stays optically centred, and that the pair reads on the dark surface as well
// as the light one (an icon at `onSurfaceVariant` is the one element here that
// can silently disappear into a dark page).
//
// The surface under test is [EmptyStateView] itself rather than the whole
// pane: the pane's toolbar and composer have their own baselines, and folding
// them in here would make every future toolbar change a diff a reviewer has to
// clear on five extra images.
//
// Determinism: no clock, no timers, no random. The icon's entrance is settled
// by alchemist's own pump-and-settle, so every scenario is captured at rest.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/ui/empty_state.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';

/// The five empty states, in the order the nav lists them. The last is a
/// CONCRETE list — the only one that carries the "Add a task" hint.
const _views = <(String, String)>[
  ('focus', 'Focus'),
  ('upcoming', 'Upcoming'),
  ('missed', 'Missed'),
  ('unscheduled', 'Unscheduled'),
  ('L1', 'a list'),
];

/// A pane-sized slice of the surface the state actually sits on.
const _pane = Size(300, 260);

Widget _state(String viewId, ThemeData theme) => Theme(
  data: theme,
  child: Scaffold(body: EmptyStateView(viewId: viewId)),
);

void main() {
  for (final (name, theme) in <(String, ThemeData)>[
    ('light', buildLightTheme()),
    ('dark', buildDarkTheme()),
  ]) {
    goldenTest(
      'empty states — $name',
      fileName: 'empty_states_$name',
      builder: () => GoldenTestGroup(
        columns: 3,
        children: [
          for (final (viewId, label) in _views)
            GoldenTestScenario(
              name: label,
              constraints: BoxConstraints.tight(_pane),
              child: SizedBox.fromSize(
                size: _pane,
                child: _state(viewId, theme),
              ),
            ),
        ],
      ),
    );
  }
}
