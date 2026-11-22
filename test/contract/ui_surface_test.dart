// The user-facing control inventory.
//
// For each shipped target this walks the real application's main screens and
// records every control a user can act on (buttons, menu items, switches,
// fields), by accessible label. The committed inventory in
// `test/contract/ui_surface/` is the reviewed baseline.
//
// What fails:
//   - a control that disappeared and is not accounted for in
//     `approved_removals.json` (a rename names its replacement; a true
//     removal needs the owner's approval);
//   - a new control that is not recorded yet. Record it with
//       flutter test test/contract/ui_surface_test.dart --update-goldens
//     and commit the inventory; no approval is needed to add.
//
// What does not fail: colours, spacing, fonts, icons, animation, layout
// changes or a Flutter upgrade. The inventory holds labels and roles only.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'product_harness.dart';

typedef _Open = Future<void> Function(ProductFixture fixture);

/// The screens inventoried, each reached the way a user reaches it.
final _screens = <String, _Open>{
  'home': (f) async {},
  'app-menu': (f) => f.openAppMenu(),
  'collection-menu': (f) => f.openCollectionMenu(),
  'navigation': (f) async {
    if (f.target.isPhone) await f.tap(find.byTooltip('Open navigation'));
  },
  'task-details': (f) => f.tap(find.text('Verified synthetic task')),
  'task-row-menu': (f) =>
      f.tap(find.byTooltip('Task actions for Verified synthetic task')),
  'export': (f) async {
    await f.openCollectionMenu();
    await f.tap(find.byKey(const Key('collection-export')));
  },
  'settings': (f) => f.openSettings(),
  'about': (f) async {
    await f.openAppMenu();
    await f.tap(find.text('About Axiotask'));
  },
  'account': (f) async {
    await f.openAppMenu();
    await f.tap(find.text('Account'));
  },
  'sync-activity': (f) async {
    await f.openAppMenu();
    await f.tap(find.text('Sync activity'));
  },
  'account-backup': (f) async {
    await f.openAppMenu();
    await f.tap(find.text('Account backup'));
  },
  'local-data-recovery': (f) async {
    await f.openAppMenu();
    await f.tap(find.text('Local data recovery'));
  },
};

void main() {
  for (final target in ProductTarget.values) {
    testWidgets('user-facing controls on ${target.name} match the inventory', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final current = <String>{};
      for (final MapEntry(key: screen, value: open) in _screens.entries) {
        final fixture = await ProductFixture.pump(tester, target);
        try {
          await open(fixture);
          for (final control in await _controlsOnScreen(tester)) {
            current.add('$screen | $control');
          }
        } finally {
          await fixture.dispose();
        }
      }
      semantics.dispose();

      final file = File('test/contract/ui_surface/${target.name}.txt');
      final recorded = file.existsSync()
          ? file
                .readAsLinesSync()
                .where((line) => line.isNotEmpty && !line.startsWith('#'))
                .toSet()
          : <String>{};
      final removed = recorded.difference(current).toList()..sort();
      final added = current.difference(recorded).toList()..sort();
      final unapproved = _unapprovedRemovals(target.name, removed, current);

      expect(
        unapproved,
        isEmpty,
        reason:
            'User-facing controls disappeared from the ${target.name} '
            'application:\n  ${unapproved.join('\n  ')}\n'
            'If a control was renamed or moved, record it in '
            'test/contract/approved_removals.json under "removed_controls" '
            'with "replaced_by" naming the new inventory line. Removing a '
            'control outright needs the owner\'s approval ("owner_approval"). '
            'Otherwise restore the control.',
      );

      if (autoUpdateGoldenFiles) {
        final sorted = current.toList()..sort();
        file
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '# User-facing controls of the ${target.name} application, by '
            'screen.\n'
            '# Generated: flutter test test/contract/ui_surface_test.dart '
            '--update-goldens\n'
            '${sorted.join('\n')}\n',
          );
        return;
      }
      expect(
        added,
        isEmpty,
        reason:
            'New user-facing controls are not in the inventory yet:\n  '
            '${added.join('\n  ')}\n'
            'Record them: flutter test test/contract/ui_surface_test.dart '
            '--update-goldens',
      );
      expect(
        removed,
        isEmpty,
        reason:
            'These approved removals are still listed in the inventory; '
            'regenerate it: flutter test '
            'test/contract/ui_surface_test.dart --update-goldens',
      );
    });
  }
}

/// Removed inventory lines that `approved_removals.json` does not cover.
List<String> _unapprovedRemovals(
  String target,
  List<String> removed,
  Set<String> current,
) {
  final ledger = jsonDecode(
    File('test/contract/approved_removals.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final approved = <String>{};
  for (final entry
      in (ledger['removed_controls']! as List<Object?>)
          .cast<Map<String, Object?>>()) {
    if (entry['target'] != target) continue;
    final replacedBy = entry['replaced_by'] as String?;
    final ownerApproval = entry['owner_approval'] as String?;
    final covered =
        (replacedBy != null && current.contains(replacedBy)) ||
        (ownerApproval != null && ownerApproval.trim().isNotEmpty);
    if (covered) approved.add(entry['control']! as String);
  }
  return removed.where((line) => !approved.contains(line)).toList();
}

/// Every actionable control on the frontmost screen, including the parts of
/// its scrolling lists that are built only when scrolled to.
Future<Set<String>> _controlsOnScreen(WidgetTester tester) async {
  final controls = _visibleControls(tester);
  final scrollables = find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );
  if (scrollables.evaluate().isEmpty) return controls;
  final scrollable = scrollables.last;
  for (var page = 0; page < 12; page += 1) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    position.jumpTo(
      (position.pixels + position.viewportDimension * 0.8).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
    await tester.pumpAndSettle();
    controls.addAll(_visibleControls(tester));
  }
  return controls;
}

Set<String> _visibleControls(WidgetTester tester) {
  final controls = <String>{};
  final root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    final flags = data.flagsCollection;
    if (!flags.isHidden) {
      final role = flags.isTextField
          ? 'field'
          : flags.isToggled != Tristate.none
          ? 'switch'
          : flags.isChecked != CheckedState.none
          ? 'choice'
          : flags.isLink
          ? 'link'
          : flags.isButton
          ? 'button'
          : data.hasAction(SemanticsAction.tap)
          ? 'action'
          : null;
      final label = <String>[
        data.label,
        if (data.label.isEmpty) data.tooltip,
        if (data.label.isEmpty && data.tooltip.isEmpty) data.hint,
      ].where((part) => part.isNotEmpty).join(' ');
      if (role != null && label.isNotEmpty) {
        controls.add('$role: ${_controlName(label)}');
      }
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return controls;
}

/// The stable name of a control: its first line and first sentence, without
/// selection state. Supporting text and state wording may change freely
/// without counting as a removed control.
String _controlName(String label) {
  var name = label.split('\n').first.trim();
  final sentenceEnd = name.indexOf('. ');
  if (sentenceEnd > 0) name = name.substring(0, sentenceEnd);
  return name.replaceAll(RegExp(r', selected$'), '');
}
