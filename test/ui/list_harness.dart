// Shared harness for the T7.6 list-surface suites (BulkOps, ContextMenu,
// DemoteToSubtask, MoveToList, DragAndDrop). Pumps the real [TaskListView] over
// the same in-memory [FakeCommands] the detail suites use (it ACTUALLY mutates
// its task set and re-emits), so the tests assert what RENDERS and what the fake
// HOLDS — never that a method merely fired. Reuses detail_harness's fake so the
// two surfaces share one Commands double.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/composer_controller.dart';
import 'package:axiotask/src/ui/detail_motion.dart';
import 'package:axiotask/src/ui/haptics.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeCommands;
import 'toast_harness.dart' show wrapWithToast;

/// A fixed clock so the quick-date bulk ops resolve deterministically.
final testClock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// The device insets a modern phone actually has: a status bar / notch at the
/// top, the gesture pill at the bottom, and a cutout down one side. The shape
/// every phone-sized surface must render inside — nothing may hide under the
/// notch, and nothing tappable may sit under the pill (#166/#160).
const phoneInsets = EdgeInsets.only(top: 48, bottom: 34, left: 20, right: 16);

/// Pump [TaskListView] on a desktop-width surface (or [size]) over a
/// [FakeCommands] seeded with [initial] and [lists]. Navigation callbacks are
/// captured into [opened] / [openedNotes] so a test can assert the intent.
///
/// [hapticsDevice] overrides the raw device seam (#257) with a recorder, and
/// [haptics] drives the pref that gates it — so a suite can assert both what a
/// gesture asked the device for and that the pref silences it.
///
/// [selection] stands in for the ROUTER-derived `selectedTaskId` the real
/// ViewListPane passes down: pushing a new value into it and pumping is exactly
/// what a route change (row tap, search jump, detail prev/next) does to this
/// widget, without needing a router in the test. Omit it for a closed detail.
///
/// [padding] injects the DEVICE INSETS a real phone always has — a status bar
/// at the top, a gesture pill at the bottom, and on some devices a cutout down
/// one side. Every other scenario renders on an inset-free surface, which is
/// exactly where an inset bug hides: with a zero inset, counting one twice
/// costs nothing. Pass [phoneInsets] for the shape a modern phone actually
/// has.
Future<FakeCommands> pumpList(
  WidgetTester tester, {
  required List<StoredTask> initial,
  required List<StoredTaskList> lists,
  String viewId = 'all',
  bool showCompleted = false,
  Map<String, String> sortPerView = const {},
  List<String>? opened,
  List<String>? openedNotes,
  Size size = const Size(1200, 1400),
  TargetPlatform? platform,
  ThemeData? theme,
  UrlOpener? urlOpener,
  String Function()? newId,
  ValueNotifier<String?>? selection,
  bool disableAnimations = false,
  double textScale = 1.0,
  DetailOriginController? originScope,
  Haptics? hapticsDevice,
  bool haptics = true,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  // A unique-id generator by default: the manual-sort list is a
  // ReorderableListView, whose per-child GlobalKeys crash on duplicate task ids
  // (the fake's bare 'gen' default). The real app's newLocalId is unique too.
  var seq = 0;
  final fake = FakeCommands(initial, newId: newId ?? (() => 'gen-${seq++}'));
  addTearDown(fake.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final selected = selection ?? ValueNotifier<String?>(null);
  if (selection == null) addTearDown(selected.dispose);

  await withClock(testClock, () async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(
            Prefs(
              showCompleted: showCompleted,
              sortPerView: sortPerView,
              haptics: haptics,
            ),
          ),
          if (hapticsDevice != null)
            hapticsDeviceProvider.overrideWithValue(hapticsDevice),
          commandsProvider.overrideWithValue(fake),
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
          listsProvider.overrideWith((ref) => Stream.value(lists)),
          if (urlOpener != null) urlOpenerProvider.overrideWithValue(urlOpener),
        ],
        child: MaterialApp(
          // The per-row action surface is chosen by POINTER capability, not
          // window width (F16 #194) — a touch platform (default in tests) shows
          // the "⋯" overflow at every width, a desktop platform reaches the same
          // actions by right-click. Tests pin the desktop path by overriding it.
          // A suite that cares about the REAL surfaces (contrast, text scale)
          // passes the app's own [theme]; everyone else keeps the default.
          theme: theme == null
              ? (platform == null ? null : ThemeData(platform: platform))
              : (platform == null ? theme : theme.copyWith(platform: platform)),
          // Mount the F19 toast overlay so migrated undo/info toasts render.
          // [disableAnimations] stands in for the platform accessibility flag
          // (Android "remove animations" / desktop reduced motion), which the
          // completion sequence honours by jumping to its end state (#241).
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
              textScaler: TextScaler.linear(textScale),
              padding: padding,
              viewPadding: padding,
            ),
            child: wrapWithToast(context, child),
          ),
          home: Scaffold(
            body: ValueListenableBuilder<String?>(
              valueListenable: selected,
              builder: (context, selectedTaskId, _) {
                // The composer lives ABOVE the view switch in the app
                // (#274), so the harness mounts it above the pane too — the
                // quick-add bar, the FAB's sheet and the bulk-add dialog all
                // come from it.
                final view = ComposerHost(
                  viewId: viewId,
                  selectedTaskId: selectedTaskId,
                  onOpenTask: (opened ?? <String>[]).add,
                  onOpenInView: (_, id) => (opened ?? <String>[]).add(id),
                  child: TaskListView(
                    viewId: viewId,
                    selectedTaskId: selectedTaskId,
                    onOpenTask: (opened ?? <String>[]).add,
                    onOpenTaskNotes: (openedNotes ?? <String>[]).add,
                  ),
                );
                // The shell publishes this scope over the list (#253); a suite
                // that cares where a row said it was passes its own controller.
                return originScope == null
                    ? view
                    : DetailOriginScope(controller: originScope, child: view);
              },
            ),
          ),
        ),
      ),
    );
    await settleList(tester);
  });
  return fake;
}

/// Bounded pump — never pumpAndSettle with a focused TextField (its cursor
/// timer never idles under the fake zone; see the widget-test-drift-async memo).
Future<void> settleList(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}
