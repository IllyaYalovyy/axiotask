import 'package:axiotask/src/app/lifecycle.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/connectivity/connectivity.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:drift/drift.dart';

import 'fake_auth.dart';
import 'fake_clock.dart';
import 'fake_connectivity.dart';
import 'fake_lifecycle.dart';
import 'fake_random.dart';

/// One isolated installation connected to the shared remote test service.
///
/// The public collaborators retain their production port types. The `*Control`
/// fields expose deterministic test controls without introducing alternate
/// repository, coordinator, or synchronization interfaces.
final class MultiHost {
  MultiHost._({
    required this.installationId,
    required this.store,
    required this.googleTasks,
    required this.clockControl,
    required this.randomControl,
    required this.authorizationControl,
    required this.lifecycleControl,
    required this.connectivityControl,
  });

  final String installationId;
  final AppDatabase store;
  final GoogleTasksService googleTasks;
  final FakeClock clockControl;
  final FakeRandom randomControl;
  final FakeAuthorization authorizationControl;
  final FakeLifecycle lifecycleControl;
  final FakeConnectivity connectivityControl;

  Clock get clock => clockControl;
  RandomSource get random => randomControl;
  AuthorizationPort get authorization => authorizationControl;
  LifecyclePort get lifecycle => lifecycleControl;
  ConnectivityPort get connectivity => connectivityControl;

  Future<void> close() async {
    await authorizationControl.close();
    await lifecycleControl.close();
    await connectivityControl.close();
    await store.close();
  }
}

/// Owns two or three installation-local stores and deterministic adapters.
///
/// [googleTasks] is deliberately caller-owned: all hosts receive the same
/// production service port, and closing the harness does not close that shared
/// service. A later integration test may therefore inspect its final ledger.
final class MultiHostHarness {
  MultiHostHarness._(this.googleTasks, this.hosts);

  static Future<MultiHostHarness> create({
    required int hostCount,
    required GoogleTasksService googleTasks,
    required AccountSubject accountSubject,
    required DateTime initialWallTime,
    required int seed,
  }) async {
    if (hostCount < 2 || hostCount > 3) {
      throw ArgumentError.value(hostCount, 'hostCount', 'must be 2 or 3');
    }
    if (accountSubject.isEmpty) {
      throw ArgumentError.value(
        accountSubject,
        'accountSubject',
        'must not be empty',
      );
    }
    if (!initialWallTime.isUtc) {
      throw ArgumentError.value(
        initialWallTime,
        'initialWallTime',
        'must be UTC',
      );
    }
    final hosts = <MultiHost>[];
    final priorWarningSetting =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    try {
      // Multiple instances are intentional and every factory call creates its
      // own executor; Drift's type-level debug warning cannot infer that.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      for (var index = 0; index < hostCount; index += 1) {
        hosts.add(
          MultiHost._(
            installationId: 'host-${index + 1}',
            store: AppDatabase.inMemory(),
            googleTasks: googleTasks,
            clockControl: FakeClock(initialWallTime),
            randomControl: FakeRandom.seeded(seed + index),
            authorizationControl: FakeAuthorization(
              initialState: TasksAuthorized(accountSubject),
            ),
            lifecycleControl: FakeLifecycle(),
            connectivityControl: FakeConnectivity(),
          ),
        );
      }
    } finally {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = priorWarningSetting;
    }
    return MultiHostHarness._(googleTasks, List<MultiHost>.unmodifiable(hosts));
  }

  final GoogleTasksService googleTasks;
  final List<MultiHost> hosts;
  var _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final host in hosts) {
      await host.close();
    }
  }
}

/// Produces every deterministic order exactly once without mutating [hosts].
Iterable<List<T>> hostOrderingPermutations<T>(List<T> hosts) sync* {
  if (hosts.isEmpty) {
    yield List<T>.unmodifiable(<T>[]);
    return;
  }
  for (var index = 0; index < hosts.length; index += 1) {
    final remaining = List<T>.of(hosts)..removeAt(index);
    for (final suffix in hostOrderingPermutations(remaining)) {
      yield List<T>.unmodifiable(<T>[hosts[index], ...suffix]);
    }
  }
}
