// #233 — a bottom view inset that outlives the keyboard.
//
// On device the shell was seen holding a roughly half-screen bottom inset with
// NO keyboard on screen: `resizeToAvoidBottomInset` dutifully reserved the
// space, so the body occupied the top half, the rest was black, and the FAB
// floated at the phantom boundary while the bottom navigation bar still drew at
// the true bottom of the screen.
//
// These tests drive the shell's own recovery contract through the only thing
// the user can see — WHERE THE BODY ENDS:
//
//   • an inset nothing can be typing into is released, and the body reoccupies
//     the screen (the black region cannot persist);
//   • an inset a FOCUSED field is sitting above is never taken away (the #166
//     contract: inputs stay above the keyboard);
//   • the release is not sticky — a real keyboard raised afterwards lifts the
//     body again.
//
// The stale-inset trigger itself is engine-side and unreproduced; this suite
// pins the RECOVERY, not the cause. The keyboard-vs-phantom distinction is
// expressed exactly as the app must make it: is anything focused?

import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const phone = Size(400, 800);
  const marker = Key('body-marker');

  // Longer than any IME hide animation, and longer than the shell's own
  // staleness window — a literal here so the test states the user-facing
  // promise ("the screen comes back within a moment") rather than quoting the
  // implementation's constant back at it.
  const wellPastAnyHideAnimation = Duration(seconds: 3);

  final destinations = [
    for (final v in SmartView.values)
      ShellDestination(
        icon: v.icon,
        selectedIcon: v.selectedIcon,
        label: v.label,
      ),
  ];

  // Pump the REAL compact shell at phone size with a live bottom view inset.
  // [inset] is driven through a ValueNotifier so a test can change the inset
  // mid-test exactly as the platform does, without remounting the tree (a
  // remount would hide any sticky state, which is the point of the third test).
  Future<void> pumpShell(
    WidgetTester tester, {
    required ValueNotifier<double> inset,
    required Widget body,
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<double>(
          valueListenable: inset,
          builder: (context, bottom, _) => MediaQuery(
            data: MediaQueryData(
              size: phone,
              viewInsets: EdgeInsets.only(bottom: bottom),
            ),
            child: ListDetailScaffold(
              sidebar: const Text('SIDEBAR'),
              destinations: destinations,
              selectedIndex: SmartView.all.index,
              onDestinationSelected: _ignoreIndex,
              title: 'All Tasks',
              onNewTask: _ignore,
              list: body,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Where the body's bottom edge currently sits.
  double bodyBottom(WidgetTester tester) =>
      tester.getRect(find.byKey(marker)).bottom;

  // A body with nothing that can take text input — the phantom-inset case.
  const inertBody = SizedBox.expand(
    key: marker,
    child: ColoredBox(color: Color(0xFF00FF00)),
  );

  // A body whose field takes focus on mount — the real-keyboard case.
  const typingBody = SizedBox.expand(
    key: marker,
    child: Column(
      children: [
        TextField(
          autofocus: true,
          decoration: InputDecoration(hintText: 'type here'),
        ),
      ],
    ),
  );

  testWidgets(
    'a bottom inset that outlives the keyboard is released — the body '
    'reoccupies the screen instead of leaving a black region (#233)',
    (tester) async {
      final inset = ValueNotifier<double>(0);
      addTearDown(inset.dispose);

      await pumpShell(tester, inset: inset, body: inertBody);
      final fullHeight = bodyBottom(tester);

      // A ~half-screen inset arrives with nothing focused — the on-device symptom.
      inset.value = 400;
      await tester.pump();
      final compressed = bodyBottom(tester);
      expect(
        compressed,
        lessThan(fullHeight - 300),
        reason:
            'the shell honours the inset on arrival — it could still be a real '
            'keyboard finishing its show animation',
      );

      // Nothing is focused, so nothing can be typing into that keyboard. It is
      // not a keyboard; it is a phantom, and the screen must come back.
      await tester.pump(wellPastAnyHideAnimation);
      expect(
        bodyBottom(tester),
        fullHeight,
        reason:
            'an inset no focused field can explain must be released — otherwise '
            'the bottom of the screen stays black for the rest of the session',
      );
    },
  );

  testWidgets('a keyboard a focused field is typing into is never taken away '
      '(#166 contract holds under the #233 guard)', (tester) async {
    final inset = ValueNotifier<double>(0);
    addTearDown(inset.dispose);

    await pumpShell(tester, inset: inset, body: typingBody);
    final fullHeight = bodyBottom(tester);

    inset.value = 400;
    await tester.pump();
    final lifted = bodyBottom(tester);
    expect(lifted, lessThan(fullHeight - 300));

    // The field still holds focus, so the keyboard is real however long it
    // stays up. The body must keep its lift — dropping it would shove the input
    // the user is typing into back under the keyboard.
    await tester.pump(wellPastAnyHideAnimation);
    expect(
      bodyBottom(tester),
      lifted,
      reason:
          'a focused field explains the inset; releasing it would hide the '
          'input being typed into behind the keyboard',
    );
  });

  testWidgets('releasing a phantom inset is not sticky — a real keyboard '
      'raised afterwards lifts the body again (#233)', (tester) async {
    final inset = ValueNotifier<double>(0);
    addTearDown(inset.dispose);

    // Start from the recovered state: phantom inset, nothing focused, released.
    await pumpShell(tester, inset: inset, body: inertBody);
    final fullHeight = bodyBottom(tester);
    inset.value = 400;
    await tester.pump();
    await tester.pump(wellPastAnyHideAnimation);
    expect(bodyBottom(tester), fullHeight, reason: 'phantom released');

    // The platform retracts the inset for real, then a genuine keyboard comes
    // up over a focused field.
    inset.value = 0;
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<double>(
          valueListenable: inset,
          builder: (context, bottom, _) => MediaQuery(
            data: MediaQueryData(
              size: phone,
              viewInsets: EdgeInsets.only(bottom: bottom),
            ),
            child: ListDetailScaffold(
              sidebar: const Text('SIDEBAR'),
              destinations: destinations,
              selectedIndex: SmartView.all.index,
              onDestinationSelected: _ignoreIndex,
              title: 'All Tasks',
              onNewTask: _ignore,
              list: typingBody,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    inset.value = 400;
    await tester.pump();

    expect(
      bodyBottom(tester),
      lessThan(fullHeight - 300),
      reason:
          'the guard re-arms: a keyboard raised after a recovery is honoured '
          'in full, not permanently suppressed',
    );
  });
}

void _ignore() {}

void _ignoreIndex(int _) {}
