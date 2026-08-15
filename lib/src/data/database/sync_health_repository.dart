import 'dart:async';

import '../../core/clock.dart';
import '../../domain/model/tasks.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/health/sync_health_repository.dart';
import 'sync_health_dao.dart';

final class DatabaseSyncHealthRepository implements SyncHealthRepository {
  const DatabaseSyncHealthRepository({
    required this.dao,
    required this.clock,
    required this.runtime,
  });

  final SyncHealthDao dao;
  final Clock clock;
  final SyncRuntimeFactsSource runtime;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) {
    late StreamController<SyncHealth> controller;
    StreamSubscription<PersistedSyncFacts>? durableSubscription;
    StreamSubscription<SyncRuntimeFacts>? runtimeSubscription;
    PersistedSyncFacts? durable;
    var runtimeFacts = runtime.currentFacts;

    void emit() {
      final currentDurable = durable;
      if (currentDurable == null || controller.isClosed) return;
      controller.add(
        projectSyncHealth(
          facts: currentDurable,
          runtime: runtimeFacts,
          now: clock.now(),
        ),
      );
    }

    controller = StreamController<SyncHealth>(
      onListen: () {
        durableSubscription = dao.watchFacts(accountId).listen((value) {
          durable = value;
          emit();
        }, onError: controller.addError);
        runtimeSubscription = runtime.facts.listen((value) {
          runtimeFacts = value;
          emit();
        }, onError: controller.addError);
      },
      onCancel: () async {
        await durableSubscription?.cancel();
        await runtimeSubscription?.cancel();
      },
    );
    return controller.stream;
  }
}
