import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_google_tasks_service.dart';
import 'multi_host.dart';

void main() {
  group('MultiHostHarness qualification', () {
    test(
      'isolates installation stores, local IDs, accounts, and clocks',
      () async {
        final google = FakeGoogleTasksService();
        final harness = await MultiHostHarness.create(
          hostCount: 3,
          googleTasks: google,
          accountSubject: const AccountSubject('synthetic-subject'),
          initialWallTime: DateTime.utc(2026, 8, 15, 12),
          seed: 907,
        );
        addTearDown(harness.close);

        final localAccountIds = <int>[];
        for (final host in harness.hosts) {
          localAccountIds.add(
            await host.store.createAccount('synthetic-subject'),
          );
          expect(host.googleTasks, same(google));
          expect(host.googleTasks, isA<GoogleTasksService>());
          expect(host.clock, isA<Clock>());
          expect(host.random, isA<RandomSource>());
          expect(host.authorization, isA<AuthorizationPort>());
        }

        expect(localAccountIds, <int>[1, 1, 1]);
        await harness.hosts.first.store.createAccount(
          'synthetic-other-subject',
        );
        expect(await harness.hosts.first.store.allAccounts(), hasLength(2));
        expect(await harness.hosts[1].store.allAccounts(), hasLength(1));
        expect(await harness.hosts[2].store.allAccounts(), hasLength(1));

        harness.hosts.first.clockControl.advance(const Duration(minutes: 3));
        expect(
          harness.hosts.first.clock.now(),
          DateTime.utc(2026, 8, 15, 12, 3),
        );
        expect(harness.hosts[1].clock.now(), DateTime.utc(2026, 8, 15, 12));
      },
    );

    test('enumerates every host ordering against one shared service', () async {
      final observedOrders = <List<String>>[];

      for (final expectedOrder in <List<String>>[
        <String>['host-1', 'host-2', 'host-3'],
        <String>['host-1', 'host-3', 'host-2'],
        <String>['host-2', 'host-1', 'host-3'],
        <String>['host-2', 'host-3', 'host-1'],
        <String>['host-3', 'host-1', 'host-2'],
        <String>['host-3', 'host-2', 'host-1'],
      ]) {
        final google = FakeGoogleTasksService();
        final harness = await MultiHostHarness.create(
          hostCount: 3,
          googleTasks: google,
          accountSubject: const AccountSubject('synthetic-subject'),
          initialWallTime: DateTime.utc(2026, 8, 15, 12),
          seed: 907,
        );
        final permutations = hostOrderingPermutations(harness.hosts).toList();
        final order = permutations.singleWhere(
          (candidate) =>
              candidate.map((host) => host.installationId).join(',') ==
              expectedOrder.join(','),
        );
        for (final host in order) {
          await host.googleTasks.createTaskList(
            CreateTaskListOperation(title: host.installationId),
          );
        }
        observedOrders.add(
          google.calls
              .map((call) => call.body!['title']! as String)
              .toList(growable: false),
        );
        await harness.close();
      }

      expect(observedOrders, hasLength(6));
      expect(
        observedOrders.map((order) => order.join(',')).toSet(),
        hasLength(6),
      );
    });

    test('accepts exactly two or three hosts', () async {
      Future<MultiHostHarness> create(int count) => MultiHostHarness.create(
        hostCount: count,
        googleTasks: FakeGoogleTasksService(),
        accountSubject: const AccountSubject('synthetic-subject'),
        initialWallTime: DateTime.utc(2026, 8, 15),
        seed: 1,
      );

      await expectLater(create(1), throwsArgumentError);
      await expectLater(create(4), throwsArgumentError);
    });
  });
}
