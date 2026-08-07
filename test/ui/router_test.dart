// Protects the pure routing helpers: how a URL parses into a view + selected
// task, how a view path is built, and the bare-root redirect. Keeping these
// pure lets the shell's selection logic be tested without pumping a router.

import 'package:axiotask/src/ui/router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseShellLocation', () {
    test('a view path selects the view with no task', () {
      final loc = parseShellLocation(Uri.parse('/view/focus'));
      expect(loc.viewId, 'focus');
      expect(loc.taskId, isNull);
    });

    test('a task query opens the detail for that task', () {
      final loc = parseShellLocation(Uri.parse('/view/all?task=T1'));
      expect(loc.viewId, 'all');
      expect(loc.taskId, 'T1');
    });

    test('a malformed location falls back to the all view', () {
      final loc = parseShellLocation(Uri.parse('/'));
      expect(loc.viewId, 'all');
      expect(loc.taskId, isNull);
    });

    test('an empty task query is treated as no selection', () {
      // Non-happy: ?task= with no value must not open an empty detail pane.
      final loc = parseShellLocation(Uri.parse('/view/focus?task='));
      expect(loc.viewId, 'focus');
      expect(loc.taskId, isNull);
    });
  });

  group('viewPath', () {
    test('builds a plain view path', () {
      expect(viewPath('all'), '/view/all');
    });

    test('appends a selected task as a query parameter', () {
      expect(viewPath('focus', taskId: 'T1'), '/view/focus?task=T1');
    });
  });

  group('initialRedirect', () {
    test('the bare root redirects to the default view', () {
      expect(initialRedirect('/', defaultViewId: 'focus'), '/view/focus');
    });

    test('any other location is left untouched', () {
      expect(initialRedirect('/view/all', defaultViewId: 'focus'), isNull);
      expect(
        initialRedirect('/view/all?task=T1', defaultViewId: 'focus'),
        isNull,
      );
    });
  });
}
