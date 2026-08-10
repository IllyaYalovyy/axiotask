// Protects the runtime UI-preference mutations that survive a relaunch: the
// theme choice, the onboarding-seen flag, and the show-completed toggle. These
// are the "UiStatePersistence PORT half" (showCompleted persistence) plus the
// theme/onboarding persistence the Properties dialog and onboarding rely on.
//
// Each test drives the live [PrefsController] against a REAL [PrefsStore] on a
// temp file, then reloads from disk to prove the write actually landed — the
// user-visible contract is "my choice is still there after restart", not "a
// setter was called".

import 'dart:io';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/prefs_controller.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/test_container.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_prefsctl'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PrefsStore store() => PrefsStore(File(p.join(tmp.path, 'prefs.json')));

  // A container whose controller persists to a real [PrefsStore] and whose
  // launch snapshot is [seed].
  ({PrefsController controller, PrefsStore store}) wire({
    Prefs seed = const Prefs(),
  }) {
    final s = store();
    final container = createTestContainer(
      overrides: [
        prefsProvider.overrideWithValue(seed),
        prefsStoreProvider.overrideWithValue(s),
      ],
    );
    return (
      controller: container.read(prefsControllerProvider.notifier),
      store: s,
    );
  }

  group('theme persistence', () {
    test('setTheme updates live state and persists to disk', () {
      final w = wire();
      w.controller.setTheme('light');
      expect(w.controller.state.theme, 'light');
      expect(w.store.load().theme, 'light', reason: 'survives a relaunch');
    });

    test('the launch snapshot seeds the live theme (applied on boot)', () {
      final w = wire(seed: const Prefs(theme: 'light'));
      expect(w.controller.state.theme, 'light');
    });
  });

  group('onboarding-seen persistence', () {
    test('setOnboardingSeen persists so the welcome never returns', () {
      final w = wire();
      expect(w.controller.state.onboardingSeen, isFalse);
      w.controller.setOnboardingSeen(true);
      expect(w.controller.state.onboardingSeen, isTrue);
      expect(w.store.load().onboardingSeen, isTrue);
    });
  });

  // The UiStatePersistence PORT half — the four showCompleted cases.
  group('showCompleted persistence', () {
    test('defaults showCompleted to false when no saved value', () {
      final w = wire();
      expect(w.controller.state.showCompleted, isFalse);
    });

    test('restores showCompleted=true from the saved prefs', () {
      final w = wire(seed: const Prefs(showCompleted: true));
      expect(w.controller.state.showCompleted, isTrue);
    });

    test('persists showCompleted to disk when toggled on', () {
      final w = wire();
      w.controller.setShowCompleted(true);
      expect(w.store.load().showCompleted, isTrue);
    });

    test('persists showCompleted=false when unchecked', () {
      final w = wire(seed: const Prefs(showCompleted: true));
      w.controller.setShowCompleted(false);
      expect(w.store.load().showCompleted, isFalse);
    });
  });
}
