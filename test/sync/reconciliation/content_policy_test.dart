import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/reconciliation/content_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = TaskContentSnapshot(
    title: 'Base title',
    notes: 'Base notes',
    status: TaskStatus.needsAction,
    due: TaskDate(2026, 8, 20),
  );
  final local = TaskContentSnapshot(
    title: 'Local title',
    notes: null,
    status: TaskStatus.completed,
    due: null,
  );
  final remote = TaskContentSnapshot(
    title: 'Google title',
    notes: 'Google notes',
    status: TaskStatus.needsAction,
    due: TaskDate(2026, 8, 22),
  );
  final localAt = DateTime.utc(2026, 8, 15, 12, 1);
  final remoteAt = DateTime.utc(2026, 8, 15, 12, 2);

  group('REC-001–REC-007 whole-record content policy', () {
    test('retains a change made on only one side', () {
      expect(
        reconcileWholeRecord(
          base: base,
          local: local,
          remote: base,
          localModifiedAt: localAt,
          remoteModifiedAt: remoteAt,
        ),
        WholeRecordResolution<TaskContentSnapshot>.local(
          local,
          WholeRecordResolutionReason.localOnly,
        ),
      );
      expect(
        reconcileWholeRecord(
          base: base,
          local: base,
          remote: remote,
          localModifiedAt: localAt,
          remoteModifiedAt: remoteAt,
        ),
        WholeRecordResolution<TaskContentSnapshot>.google(
          remote,
          WholeRecordResolutionReason.googleOnly,
        ),
      );
    });

    test('selects the entire strictly newer local record', () {
      final result = reconcileWholeRecord(
        base: base,
        local: local,
        remote: remote,
        localModifiedAt: remoteAt.add(const Duration(microseconds: 1)),
        remoteModifiedAt: remoteAt,
      );

      expect(
        result,
        WholeRecordResolution<TaskContentSnapshot>.local(
          local,
          WholeRecordResolutionReason.localNewer,
        ),
      );
      final resolution = result as WholeRecordResolution<TaskContentSnapshot>;
      expect(resolution.value, local);
      expect(resolution.value.notes, isNull);
      expect(resolution.value.due, isNull);
      expect(resolution.value.status, TaskStatus.completed);
    });

    test('selects the entire newer Google record without field merging', () {
      final result = reconcileWholeRecord(
        base: base,
        local: local,
        remote: remote,
        localModifiedAt: localAt,
        remoteModifiedAt: remoteAt,
      );

      expect(
        result,
        WholeRecordResolution<TaskContentSnapshot>.google(
          remote,
          WholeRecordResolutionReason.googleNewer,
        ),
      );
      expect((result as WholeRecordResolution).value, remote);
    });

    test('Google wins equal timestamps', () {
      expect(
        reconcileWholeRecord(
          base: base,
          local: local,
          remote: remote,
          localModifiedAt: remoteAt,
          remoteModifiedAt: remoteAt,
        ),
        WholeRecordResolution<TaskContentSnapshot>.google(
          remote,
          WholeRecordResolutionReason.googleTie,
        ),
      );
    });

    test(
      'matching desired Google state confirms without timestamp evidence',
      () {
        expect(
          reconcileWholeRecord(
            base: base,
            local: local,
            remote: local,
            localModifiedAt: null,
            remoteModifiedAt: null,
          ),
          WholeRecordResolution<TaskContentSnapshot>.confirmed(local),
        );
      },
    );

    test('missing or non-UTC conflict timestamps fail closed', () {
      for (final timestamps in <(DateTime?, DateTime?)>[
        (null, remoteAt),
        (localAt, null),
        (DateTime(2026, 8, 15, 12), remoteAt),
        (localAt, DateTime(2026, 8, 15, 12)),
      ]) {
        expect(
          reconcileWholeRecord(
            base: base,
            local: local,
            remote: remote,
            localModifiedAt: timestamps.$1,
            remoteModifiedAt: timestamps.$2,
          ),
          const WholeRecordConflictEvidenceFailure<TaskContentSnapshot>(),
        );
      }
    });

    test('list title uses the identical Google-on-tie policy', () {
      const baseTitle = TaskListTitleSnapshot('Base');
      const localTitle = TaskListTitleSnapshot('Local');
      const googleTitle = TaskListTitleSnapshot('Google');

      expect(
        reconcileWholeRecord(
          base: baseTitle,
          local: localTitle,
          remote: googleTitle,
          localModifiedAt: remoteAt,
          remoteModifiedAt: remoteAt,
        ),
        const WholeRecordResolution<TaskListTitleSnapshot>.google(
          googleTitle,
          WholeRecordResolutionReason.googleTie,
        ),
      );
    });
  });
}
