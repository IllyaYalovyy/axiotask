import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const namespace = 'synthetic.toggles';

  DevicePreferencesAdapter adapter(DevicePreferencesBackend backend) =>
      DevicePreferencesAdapter(
        backend: backend,
        namespace: namespace,
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
      );

  test('defaults keep the released behavior', () async {
    final preferences = await adapter(InMemoryDevicePreferencesBackend())
        .watch()
        .first;
    expect(preferences.haptics, isTrue);
    expect(preferences.collapseCompletedSubtasks, isTrue);
    expect(preferences.readOnlySync, isFalse);
    expect(preferences.autoSyncOnStartup, isTrue);
  });

  test('every toggle persists and is restored by a new adapter', () async {
    final backend = InMemoryDevicePreferencesBackend();
    final first = adapter(backend);
    for (final toggle in DeviceToggle.values) {
      final flipped = !toggle.defaultValue;
      expect(
        await first.setDeviceToggle(toggle, flipped),
        isA<Success<void>>(),
      );
      expect(
        await backend.readBool('$namespace.${toggle.storageName}'),
        flipped,
      );
    }
    await first.close();

    final restored = await adapter(backend).watch().first;
    for (final toggle in DeviceToggle.values) {
      expect(
        restored.toggle(toggle),
        !toggle.defaultValue,
        reason: '${toggle.name} survives a restart',
      );
    }
  });

  test('a change is published to watchers', () async {
    final store = adapter(InMemoryDevicePreferencesBackend());
    final seen = <bool>[];
    final subscription = store.watch().listen(
      (preferences) => seen.add(preferences.readOnlySync),
    );
    await pumpEventQueue();
    await store.setDeviceToggle(DeviceToggle.readOnlySync, true);
    await pumpEventQueue();
    await subscription.cancel();
    expect(seen, <bool>[false, true]);
  });

  test('storage names are stable', () {
    // Renaming one silently resets every user's setting.
    expect(
      <String, String>{
        for (final toggle in DeviceToggle.values)
          toggle.name: toggle.storageName,
      },
      <String, String>{
        'haptics': 'haptics',
        'collapseCompletedSubtasks': 'collapse_completed_subtasks',
        'readOnlySync': 'read_only_sync',
        'autoSyncOnStartup': 'auto_sync_on_startup',
      },
    );
  });
}
