import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/android_regression/manifest.dart';
import '../../tool/android_regression/protocol.dart';

const _auditCaseIds = <String>[
  '01_task_menu',
  '02_swipe_complete',
  '03_swipe_schedule',
  '04_complete_button_persists',
  '05_completion_undo',
  '06_long_press_selection',
  '07_quick_capture_twice',
  '08_capture_notes',
  '09_date_calendar',
  '10_edit_save_persists',
  '11_inline_detail_edit',
  '12_add_subtask_persists',
  '13_subtask_back_returns_parent',
  '14_duplicate_action',
  '15_export_action',
  '16_move_task_persists',
  '17_search_open_result',
  '18_routine_local_edit_feedback',
  '19_failure_explanation',
  '20_phone_add_affordance',
  '21_delete_and_undo',
  '22_touch_target_size',
  '23_detail_previous_next',
  '24_navigation_drawer',
  '25_date_shortcut_and_undo',
  '26_large_text_layout',
  '27_landscape_capture',
  '28_create_list',
  '29_rename_delete_list',
  '30_completed_filter_and_sort',
  '31_settings_theme',
  '32_subtask_swipe_schedule',
  '33_parent_completion_cascade',
  '34_pull_to_refresh',
  '35_touch_reorder',
  '36_detail_move_down',
];

/// Audit failures whose corrective task landed a passing native contract,
/// with the owning task. They stay out of the audited-pass baseline.
const _correctedAuditFailures = <String, String>{
  '01_task_menu': 'android-task-row-actions',
  '02_swipe_complete': 'android-touch-gestures',
  '03_swipe_schedule': 'android-touch-gestures',
  '05_completion_undo': 'android-completion-semantics',
  '06_long_press_selection': 'android-selection-toolbar',
  '08_capture_notes': 'android-capture-composer',
  '09_date_calendar': 'android-task-details',
  '11_inline_detail_edit': 'android-task-details',
  '14_duplicate_action': 'android-task-details',
  '15_export_action': 'android-export',
  '17_search_open_result': 'android-search-navigation',
  '20_phone_add_affordance': 'android-capture-composer',
  '22_touch_target_size': 'android-task-row-actions',
  '23_detail_previous_next': 'android-task-details',
  '32_subtask_swipe_schedule': 'android-touch-gestures',
  '33_parent_completion_cascade': 'android-completion-semantics',
};

/// Screenshot-backed findings beyond the 36 audit cases whose corrective
/// task landed a passing native contract, with the owning task. They are
/// not audit failures and never enter the baseline.
const _correctedFindings = <String, String>{
  'bottom-navigation': 'android-home-navigation',
  'task-row-metadata': 'android-home-navigation',
};

const _auditPassingNumbers = <String>{
  '04', '07', '10', '12', '13', '16', '19', '21', '24', //
  '25', '26', '27', '28', '29', '30', '31', '36',
};

void main() {
  final manifest = RegressionManifest.parse(
    File('integration_test/android_regression/manifest.json')
        .readAsStringSync(),
  );
  final cases = manifest.entries
      .where((entry) => entry.kind == EntryKind.auditCase)
      .toList();

  test('contains every stable audit case exactly once', () {
    expect(cases.map((entry) => entry.id), _auditCaseIds);
  });

  test('baseline is exactly the 17 audit passes with their labels', () {
    final baseline = manifest.subset('baseline');
    expect(
      baseline.map((entry) => entry.id.substring(0, 2)).toSet(),
      _auditPassingNumbers,
    );
    for (final entry in baseline) {
      expect(entry.expected, ExpectedOutcome.pass, reason: entry.id);
      expect(entry.contract, ContractState.implemented, reason: entry.id);
      expect(File(entry.testPath).existsSync(), isTrue, reason: entry.id);
    }
    expect(
      {
        for (final entry in baseline)
          if (entry.label == CaseLabel.limitedPass) entry.id.substring(0, 2),
      },
      {'19', '26', '27'},
    );
  });

  test('audit failures stay outside the baseline', () {
    final failures = cases.where(
      (entry) => !_auditPassingNumbers.contains(entry.id.substring(0, 2)),
    );
    expect(failures, hasLength(19));
    for (final entry in failures) {
      expect(entry.subsets, {'complete'}, reason: entry.id);
      expect(entry.owner, isNot('android-regression-baseline'));
    }
  });

  test('uncorrected audit failures stay outstanding expected failures', () {
    final outstanding = cases.where(
      (entry) =>
          !_auditPassingNumbers.contains(entry.id.substring(0, 2)) &&
          !_correctedAuditFailures.containsKey(entry.id),
    );
    expect(outstanding, hasLength(19 - _correctedAuditFailures.length));
    for (final entry in outstanding) {
      expect(entry.expected, ExpectedOutcome.fail, reason: entry.id);
      expect(entry.contract, ContractState.outstanding, reason: entry.id);
    }
  });

  test('corrected audit failures carry an executable passing contract', () {
    for (final MapEntry(key: id, value: owner)
        in _correctedAuditFailures.entries) {
      final entry = cases.singleWhere((candidate) => candidate.id == id);
      expect(entry.expected, ExpectedOutcome.pass, reason: id);
      expect(entry.label, CaseLabel.working, reason: id);
      expect(entry.contract, ContractState.implemented, reason: id);
      expect(entry.owner, owner, reason: id);
      expect(entry.subsets, {'complete'}, reason: id);
      final source = File(entry.testPath).readAsStringSync();
      // dart format may break the call before the case ID.
      expect(
        source,
        contains(RegExp("regressionCase\\(\\s*'${RegExp.escape(id)}'")),
        reason: id,
      );
    }
  });

  test('tracks the four non-case findings outside the audit cases', () {
    final findings = manifest.entries.where(
      (entry) => entry.kind == EntryKind.trackedFinding,
    );
    expect(findings.map((entry) => entry.id), <String>[
      'bottom-navigation',
      'task-row-metadata',
      'failure-message-usability',
      'subtask-touch-reorder',
    ]);
    for (final entry in findings) {
      expect(entry.subsets, {'complete'}, reason: entry.id);
      if (_correctedFindings.containsKey(entry.id)) continue;
      expect(entry.expected, ExpectedOutcome.fail, reason: entry.id);
      expect(entry.contract, ContractState.outstanding, reason: entry.id);
    }
  });

  test('corrected findings carry an executable passing contract', () {
    for (final MapEntry(key: id, value: owner) in _correctedFindings.entries) {
      final entry = manifest.entries.singleWhere(
        (candidate) => candidate.id == id,
      );
      expect(entry.kind, EntryKind.trackedFinding, reason: id);
      expect(entry.expected, ExpectedOutcome.pass, reason: id);
      expect(entry.label, CaseLabel.working, reason: id);
      expect(entry.contract, ContractState.implemented, reason: id);
      expect(entry.owner, owner, reason: id);
      final source = File(entry.testPath).readAsStringSync();
      expect(
        source,
        contains(RegExp("regressionCase\\(\\s*'${RegExp.escape(id)}'")),
        reason: id,
      );
    }
  });

  test('the complete gate covers every entry', () {
    expect(manifest.subset('complete'), manifest.entries);
  });

  test('rejects an expected failure that claims a passing contract', () {
    expect(
      () => RegressionManifest.parse('''
{"schema_version": 1, "manifest_version": 1,
 "subsets": {"complete": ""}, "corrective_tasks": {"fix": ""},
 "cases": [{"id": "01", "baseline": {"expected": "fail"},
            "contract": "implemented", "test_path": "t.dart",
            "owner": "fix", "subsets": ["complete"]}],
 "tracked_findings": []}'''),
      throwsFormatException,
    );
  });
}
