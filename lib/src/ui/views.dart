// The shell's view vocabulary — the five built-in smart views and the pure
// functions that map a view id to its human label and to the desktop window
// title.
//
// This is a port of the reference's `App.svelte` title map
//   { focus, upcoming, missed, unscheduled, all } → "<label> — axiotask"
// (see reference `App.svelte` + `WindowTitle.test.js`). Lists are addressed by
// their id and resolve to the list title; the shell falls back to "All Tasks"
// when an id is neither a smart view nor a known list, so an unknown/stale
// persisted view never leaves the title blank.
//
// Everything here is pure (no widgets, no plugins) so the title contract is
// unit-tested without pumping an app.

import 'package:flutter/material.dart';

/// The five built-in smart views, in the order the reference lists them (Focus
/// first). The [id] is what the router and `prefs.json` persist; [label] is the
/// window-title/nav text; the two icons drive the selected/unselected nav state.
enum SmartView {
  focus('focus', 'Focus', Icons.bolt_outlined, Icons.bolt),
  upcoming('upcoming', 'Upcoming', Icons.upcoming_outlined, Icons.upcoming),
  missed('missed', 'Missed', Icons.error_outline, Icons.error),
  unscheduled(
    'unscheduled',
    'Unscheduled',
    Icons.event_busy_outlined,
    Icons.event_busy,
  ),
  all('all', 'All Tasks', Icons.checklist_outlined, Icons.checklist);

  const SmartView(this.id, this.label, this.icon, this.selectedIcon);

  /// The stable id persisted in the route and `prefs.json`.
  final String id;

  /// Human-readable name — shown in the nav and the window title.
  final String label;

  /// Nav icon when this view is not selected.
  final IconData icon;

  /// Nav icon when this view is selected.
  final IconData selectedIcon;

  /// The smart view with this [id], or `null` if [id] is a list id (or unknown).
  static SmartView? byId(String id) {
    for (final v in values) {
      if (v.id == id) return v;
    }
    return null;
  }
}

/// The human label for [viewId]: a smart-view name, else the matching entry in
/// [listTitles], else the "All Tasks" fallback (never blank — a stale persisted
/// view id must still yield a sensible title).
String viewLabelFor(
  String viewId, {
  Map<String, String> listTitles = const {},
}) {
  return SmartView.byId(viewId)?.label ??
      listTitles[viewId] ??
      SmartView.all.label;
}

/// The desktop window title for the current [viewId]: `"<label> — axiotask"`,
/// with the instance prefix preserved for a dev instance
/// (`"<label> — axiotask (dev)"`) so an isolated run is never mistaken for
/// production. The em dash matches the reference contract exactly.
String windowTitleFor(
  String viewId, {
  String? instancePrefix,
  Map<String, String> listTitles = const {},
}) {
  final label = viewLabelFor(viewId, listTitles: listTitles);
  final suffix = instancePrefix == null
      ? 'axiotask'
      : 'axiotask ($instancePrefix)';
  return '$label — $suffix';
}
