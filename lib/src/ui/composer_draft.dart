// The quick-add composer's DRAFT AIM — everything about the next add that is
// not the typed title: an explicitly picked due date, the phrase the user chose
// to keep as literal text, and the destination list.
//
// It is ONE object per mounted list pane, observed by BOTH composer surfaces:
// the always-visible desktop bar and the phone's bottom-sheet composer. That is
// the whole point of it. Before #264 the aim lived in the pane's own `State`
// fields, and the sheet — a route on the ROOT navigator, built once — captured
// their values at build time while the pane went on mutating them. A submit
// cleared the picked date underneath a chip that kept drawing it, so the
// composer said "tomorrow" and created an undated task. A [Listenable] both bars
// build from cannot drift like that: there is exactly one value and every
// surface showing it rebuilds when it changes.
//
// Ratified semantics (#264): the aim is what the NEXT add will use, so it stays
// put across submits — the title is what a create consumes, not the aim. It goes
// away when the user says so (the date chip's ×, "Clear" in the quick-date set)
// or when the composer is released: the sheet closing, or a view change, both of
// which end the session the aim belonged to.

import 'package:flutter/foundation.dart';

class ComposerDraft extends ChangeNotifier {
  String? _pickedDue;

  /// A date set EXPLICITLY on the draft — the composer's date button or its
  /// calendar (#243) — as a bare `YYYY-MM-DD`; `null` when the draft carries no
  /// explicit pick. An explicit pick OUTRANKS a date phrase parsed out of the
  /// title: the user said what they meant with a tap, so typing "next week"
  /// afterwards does not silently overrule it.
  String? get pickedDue => _pickedDue;

  String _dateIgnoredFor = '';

  /// The exact input text whose parsed date the user chose to keep as literal
  /// title text, so its phrase is not re-read as a due date. Bound to that text:
  /// editing away from it makes the phrase live again.
  String get dateIgnoredFor => _dateIgnoredFor;

  String? _pickedListId;

  /// The list the user aimed the composer at (#217), or `null` while it still
  /// follows the view's own default. Never persisted to prefs.
  String? get pickedListId => _pickedListId;

  /// Set an explicit due date on the draft.
  void pickDue(String ymd) {
    if (_pickedDue == ymd) return;
    _pickedDue = ymd;
    notifyListeners();
  }

  /// The date chip's × and the quick-date set's "Clear": drop any explicit pick
  /// AND silence a date phrase already typed in [draftText], so "no date" means
  /// no date however the date got there.
  void keepAsText(String draftText) {
    if (_pickedDue == null && _dateIgnoredFor == draftText) return;
    _pickedDue = null;
    _dateIgnoredFor = draftText;
    notifyListeners();
  }

  /// Aim the next add at [listId].
  void aimAtList(String listId) {
    if (_pickedListId == listId) return;
    _pickedListId = listId;
    notifyListeners();
  }

  /// The drafted title has left the composer — it became a task, or a run of
  /// tasks through the paste split. The phrase-silence belonged to that text and
  /// goes with it; the AIM is what the user set for the adds that FOLLOW and
  /// stays exactly where it is (#264).
  ///
  /// Always notifies: the surfaces showing the draft have to re-read a composer
  /// whose title just went away, even when the aim itself did not move.
  void titleConsumed() {
    _dateIgnoredFor = '';
    notifyListeners();
  }

  /// Give the aim back to the view's defaults — the composer session it belonged
  /// to is over. The sheet closing and a view change both end one; the desktop
  /// bar, which never closes, only ever sees the view change.
  void release() {
    if (_pickedDue == null &&
        _pickedListId == null &&
        _dateIgnoredFor.isEmpty) {
      return;
    }
    _pickedDue = null;
    _pickedListId = null;
    _dateIgnoredFor = '';
    notifyListeners();
  }
}
