// The live UI-preferences controller — the reactive seam over the immutable
// [Prefs] snapshot. The static [prefsProvider] holds the value loaded at launch
// (theme + initial view read it once); this controller lets the running UI
// MUTATE prefs — the show-completed toggle, the per-view sort, list exclusion,
// and list order — with each change persisted through [prefsStoreProvider] and
// pushed to every watcher.
//
// Persistence is best-effort: a widget test that pumps a surface without a
// [prefsStoreProvider] override still gets live in-memory prefs (the save is
// skipped), while the real app and the shell tests override the store and
// observe the write on disk.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/task_view.dart' show SortMode;
import 'prefs.dart';
import 'providers.dart';

/// Mutable UI-preferences state, seeded from the launch snapshot.
class PrefsController extends Notifier<Prefs> {
  @override
  Prefs build() => ref.watch(prefsProvider);

  void _write(Prefs next) {
    // Update the live state first so the UI always reflects the edit, then try
    // to persist. Persistence is best-effort (the reference's localStorage is
    // too): with no [prefsStoreProvider] override in scope (a widget-only test)
    // the read throws, and a disk failure on a UI pref is not worth surfacing.
    state = next;
    try {
      ref.read(prefsStoreProvider).save(next);
    } catch (_) {
      // No store to persist to, or the save failed — keep the in-memory edit.
    }
  }

  /// Persist the last-selected view (survives restart).
  void setView(String viewId) => _write(state.copyWith(view: viewId));

  /// Set the theme preference ('system' | 'light' | 'dark'). Persisted and
  /// pushed to every watcher so the app re-themes live (the Appearance radio and
  /// the sidebar sun/moon toggle both call this).
  void setTheme(String theme) => _write(state.copyWith(theme: theme));

  /// Mark the first-launch onboarding intro as seen — persisted so the welcome
  /// never shows again once dismissed (the reference's `onboardingSeen`).
  void setOnboardingSeen(bool value) =>
      _write(state.copyWith(onboardingSeen: value));

  /// Show or hide completed tasks across the views.
  void setShowCompleted(bool value) =>
      _write(state.copyWith(showCompleted: value));

  /// Turn the haptic vocabulary on or off (#257). Persisted, and read by
  /// `hapticsProvider`, so flipping it silences (or restores) every event at
  /// once without any call site knowing.
  void setHaptics(bool value) => _write(state.copyWith(haptics: value));

  /// Collapse or reveal completed subtasks in the detail panel checklist.
  /// Persisted so a tidy checklist stays tidy across panels and sessions.
  void setHideCompletedSubtasks(bool value) =>
      _write(state.copyWith(hideCompletedSubtasks: value));

  /// Set the sort order for one view id (persisted per view).
  void setSort(String viewId, SortMode mode) {
    final next = Map<String, String>.from(state.sortPerView)
      ..[viewId] = mode.id;
    _write(state.copyWith(sortPerView: next));
  }

  /// Toggle a list's exclusion from the smart views.
  void toggleExclude(String listId) {
    final next = [...state.excludedLists];
    if (next.contains(listId)) {
      next.remove(listId);
    } else {
      next.add(listId);
    }
    _write(state.copyWith(excludedLists: next));
  }

  /// Replace the user-defined list order.
  void setListOrder(List<String> ids) =>
      _write(state.copyWith(listOrder: List.of(ids)));

  /// Persist the desktop sidebar width after a divider drag or a reset (#210).
  /// The value is already clamped to the draggable range by the layout; this is
  /// pure persistence, called once per gesture (not per drag frame).
  void setSidebarWidth(double width) =>
      _write(state.copyWith(sidebarWidth: width));

  /// Persist the desktop detail-pane width fraction after a divider drag or a
  /// reset (#210). Already clamped by the layout; one write per gesture.
  void setDetailFraction(double fraction) =>
      _write(state.copyWith(detailFraction: fraction));
}

/// The live UI preferences. Watch this (not [prefsProvider]) for anything the
/// user can change at runtime.
final prefsControllerProvider = NotifierProvider<PrefsController, Prefs>(
  PrefsController.new,
);
