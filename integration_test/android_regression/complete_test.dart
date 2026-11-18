// One APK for the complete manifest. Each case still has its own isolated
// database, native preference namespace, teardown and reported outcome.
import 'baseline_test.dart' as baseline;
import 'capture_test.dart' as capture;
import 'completion_test.dart' as completion;
import 'export_test.dart' as exports;
import 'home_navigation_test.dart' as home;
import 'search_test.dart' as search;
import 'selection_test.dart' as selection;
import 'sync_status_test.dart' as sync;
import 'task_details_test.dart' as details;
import 'task_row_test.dart' as row;
import 'touch_gestures_test.dart' as touch;

void main() {
  baseline.main();
  capture.main();
  completion.main();
  exports.main();
  home.main();
  search.main();
  selection.main();
  sync.main();
  details.main();
  row.main();
  touch.main();
}
