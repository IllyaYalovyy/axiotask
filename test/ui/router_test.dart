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

    test('a from query records the panel the detail was opened from', () {
      // #310: the origin is part of the URL, so it survives a restore.
      final loc = parseShellLocation(Uri.parse('/view/all?task=S1&from=P'));
      expect(loc.taskId, 'S1');
      expect(loc.fromTaskId, 'P');
    });

    test('an empty from query is no origin', () {
      // Non-happy: ?from= must not send Back to a panel with a blank id.
      final loc = parseShellLocation(Uri.parse('/view/all?task=S1&from='));
      expect(loc.taskId, 'S1');
      expect(loc.fromTaskId, isNull);
    });
  });

  group('viewPath', () {
    test('builds a plain view path', () {
      expect(viewPath('all'), '/view/all');
    });

    test('appends a selected task as a query parameter', () {
      expect(viewPath('focus', taskId: 'T1'), '/view/focus?task=T1');
    });

    test('appends the origin panel when there is one', () {
      expect(
        viewPath('all', taskId: 'S1', fromTaskId: 'P'),
        '/view/all?task=S1&from=P',
      );
    });

    test('an origin without a selected task is dropped', () {
      // Non-happy: there is no panel to go back FROM, so nothing to record.
      expect(viewPath('all', fromTaskId: 'P'), '/view/all');
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
