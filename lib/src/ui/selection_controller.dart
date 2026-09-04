// The list's multi-select (BulkOps), as a [Listenable] rather than pane state
// (#274).
//
// Selection changes what the bulk bar says and how a row paints, and nothing
// else — not the toolbar, not the composer, and above all not the row
// derivation. Holding it in the pane's `State` meant every Ctrl-click rebuilt
// the whole pane and re-ran the view's filter/sort/effective-due sweep. As a
// controller the only things that rebuild are the surfaces that listen.
//
// Selection MODE is deliberately separate from "something is selected": the
// toolbar's "Select tasks" (#245) enters the mode with an EMPTY selection — the
// visible touch entry that replaced the retired row menu's "Select". While the
// mode is on a plain row tap toggles membership instead of opening the detail.
// Deselecting the last row leaves the mode (the Android convention), so the
// list never gets stuck in it.

import 'dart:collection';

import 'package:flutter/foundation.dart';

class SelectionController extends ChangeNotifier {
  final Set<String> _ids = {};
  bool _active = false;

  /// The selected task ids.
  Set<String> get ids => UnmodifiableSetView(_ids);

  int get count => _ids.length;

  bool contains(String id) => _ids.contains(id);

  /// Whether selection MODE is on — the bulk bar is up and a row tap toggles.
  bool get active => _active;

  /// Enter the mode with nothing selected. The bar appears named-but-disarmed
  /// and the next row tap selects instead of opening.
  void enter() {
    if (_active) return;
    _active = true;
    notifyListeners();
  }

  /// Add or remove [id]. Adding always turns the mode on; removing the last row
  /// turns it off rather than stranding an empty bar that still swallows taps.
  void toggle(String id) {
    if (!_ids.remove(id)) {
      _ids.add(id);
      _active = true;
    } else if (_ids.isEmpty) {
      _active = false;
    }
    notifyListeners();
  }

  /// Leave the mode with nothing selected.
  void clear() {
    if (_ids.isEmpty && !_active) return;
    _ids.clear();
    _active = false;
    notifyListeners();
  }
}
