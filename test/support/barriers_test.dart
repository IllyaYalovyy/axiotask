import 'package:flutter_test/flutter_test.dart';

import 'barriers.dart';

void main() {
  group('DeterministicBarriers qualification', () {
    test(
      'independently addresses named request and transaction boundaries',
      () async {
        final barriers = DeterministicBarriers();
        const request = BarrierAddress(
          point: BarrierPoint.beforeRequestDispatch,
          operation: 'patchTask',
          scope: 'synthetic-task-a',
        );
        const transaction = BarrierAddress(
          point: BarrierPoint.beforeTransactionCommit,
          operation: 'acknowledgeMutation',
          scope: 'synthetic-account',
        );
        const page = BarrierAddress(
          point: BarrierPoint.beforePagePublication,
          operation: 'publishRemotePage',
          scope: 'synthetic-list-a',
        );
        final requestGate = barriers.arm(request);
        final transactionGate = barriers.arm(transaction);
        final pageGate = barriers.arm(page);
        final requestWait = barriers.reach(request);
        final transactionWait = barriers.reach(transaction);
        final pageWait = barriers.reach(page);
        await Future.wait(<Future<void>>[
          requestGate.whenReached,
          transactionGate.whenReached,
          pageGate.whenReached,
        ]);

        expect(requestGate.release(), isTrue);
        expect(await requestWait, BarrierOutcome.released);
        expect(transactionGate.isWaiting, isTrue);
        expect(pageGate.isWaiting, isTrue);

        expect(pageGate.release(), isTrue);
        expect(await pageWait, BarrierOutcome.released);
        expect(transactionGate.release(), isTrue);
        expect(await transactionWait, BarrierOutcome.released);
        expect(barriers.arrivals, <BarrierAddress>[request, transaction, page]);
      },
    );

    test('cancellation and release resolve in explicit action order', () async {
      final barriers = DeterministicBarriers();
      const cancelledAddress = BarrierAddress(
        point: BarrierPoint.afterServerCommit,
        operation: 'createTask',
        scope: 'synthetic-task-cancelled',
      );
      const releasedAddress = BarrierAddress(
        point: BarrierPoint.afterServerCommit,
        operation: 'createTask',
        scope: 'synthetic-task-released',
      );
      const killedAddress = BarrierAddress(
        point: BarrierPoint.afterTransactionCommit,
        operation: 'acknowledgeMutation',
        scope: 'synthetic-child-process',
      );
      final cancelledGate = barriers.arm(cancelledAddress);
      final releasedGate = barriers.arm(releasedAddress);
      final killedGate = barriers.arm(killedAddress);
      final cancelledWait = barriers.reach(cancelledAddress);
      final releasedWait = barriers.reach(releasedAddress);
      final killedWait = barriers.reach(killedAddress);
      await Future.wait(<Future<void>>[
        cancelledGate.whenReached,
        releasedGate.whenReached,
        killedGate.whenReached,
      ]);

      expect(cancelledGate.cancel(), isTrue);
      expect(cancelledGate.release(), isFalse);
      expect(releasedGate.release(), isTrue);
      expect(releasedGate.cancel(), isFalse);
      expect(killedGate.kill(), isTrue);
      expect(killedGate.release(), isFalse);

      expect(await cancelledWait, BarrierOutcome.cancelled);
      expect(await releasedWait, BarrierOutcome.released);
      expect(await killedWait, BarrierOutcome.killed);
      expect(barriers.resolutions, <BarrierResolution>[
        const BarrierResolution(cancelledAddress, BarrierOutcome.cancelled),
        const BarrierResolution(releasedAddress, BarrierOutcome.released),
        const BarrierResolution(killedAddress, BarrierOutcome.killed),
      ]);
    });

    test('unarmed named boundaries pass without a call-count hook', () async {
      final barriers = DeterministicBarriers();
      const address = BarrierAddress(
        point: BarrierPoint.runPhase,
        operation: 'enumerate',
        scope: 'synthetic-list',
      );

      expect(await barriers.reach(address), BarrierOutcome.passed);
      expect(barriers.arrivals, <BarrierAddress>[address]);
    });
  });
}
