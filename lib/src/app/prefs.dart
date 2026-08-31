// UI preferences over `prefs.json` — the replacement for the reference's
// browser `localStorage` + `storage.js` (MIGRATION-PLAN §1). There is NO
// ui_prefs DB table.
//
// `prefs.json` lives beside the DB but OUTSIDE the schema fingerprint, so it
// SURVIVES a schema wipe, `clear_all`, and a fresh sync — localStorage parity.
// Instance isolation falls out of the per-instance data dir (see instance.dart).
//
// This file owns the data model + durable load/save. The typed fields are the
// full prefs vocabulary the later UI tasks consume (theme, view, sort-per-view,
// showCompleted, excludedLists, listOrder, onboardingSeen, hideCompleted-
// Subtasks, window size); T2.1 wires only the window-size half (windowing).
// Unknown keys already on disk are preserved on save, so an older build never
// drops a newer build's prefs.

import 'dart:convert';
import 'dart:io';

/// A persisted window size (logical pixels). Position is deliberately NOT
/// stored — only size is restored (size-only persistence, windowing).
class WindowSize {
  const WindowSize(this.width, this.height);

  final double width;
  final double height;

  Map<String, Object?> toJson() => {'width': width, 'height': height};

  static WindowSize? fromJson(Object? json) {
    if (json is! Map) return null;
    final w = json['width'];
    final h = json['height'];
    if (w is num && h is num && w > 0 && h > 0) {
      return WindowSize(w.toDouble(), h.toDouble());
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is WindowSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'WindowSize(${width}x$height)';
}

/// The full set of UI preferences. Immutable; [copyWith] produces edited
/// copies that the store persists.
class Prefs {
  const Prefs({
    this.theme = 'dark',
    this.view = 'all',
    this.sortPerView = const {},
    this.showCompleted = false,
    this.excludedLists = const [],
    this.listOrder = const [],
    this.onboardingSeen = false,
    this.hideCompletedSubtasks = false,
    this.haptics = true,
    this.windowSize,
    this.sidebarWidth,
    this.detailFraction,
    this.unknownKeys = const {},
  });

  /// 'system' | 'light' | 'dark'. Defaults to `dark` (ratified default-dark, the
  /// reference's `getThemePref()` fallback) — a fresh install opens dark until
  /// the user chooses otherwise. An unrecognized value resolves to system.
  final String theme;

  /// The active view id (smart view or list).
  final String view;

  /// Sort order keyed by view id.
  final Map<String, String> sortPerView;

  /// Whether completed tasks are shown.
  final bool showCompleted;

  /// List ids hidden from smart views.
  final List<String> excludedLists;

  /// User-defined ordering of lists.
  final List<String> listOrder;

  /// Whether the first-launch onboarding intro has been dismissed.
  final bool onboardingSeen;

  /// Whether completed subtasks are hidden in the detail panel.
  final bool hideCompletedSubtasks;

  /// Whether the app answers a gesture with a haptic tick (#257). ON by
  /// default — tactile confirmation is the cheapest "it happened" signal a
  /// phone has, so it is opt-OUT. Android only: on the desktop the seam is a
  /// no-op and the toggle is not rendered at all.
  final bool haptics;

  /// Persisted window size, or `null` if never saved. Size-only (no position).
  final WindowSize? windowSize;

  /// Persisted desktop sidebar width (logical px), or `null` when never dragged
  /// — the expanded layout then falls back to its default width. Clamped by the
  /// UI to the draggable range (#210).
  final double? sidebarWidth;

  /// Persisted desktop detail-pane width as a fraction (0–1) of the list+detail
  /// region, or `null` when never dragged — the expanded layout then falls back
  /// to its default split. Clamped by the UI to the draggable range (#210).
  final double? detailFraction;

  /// Keys present on disk this build does not know — preserved verbatim so a
  /// newer build's prefs survive an older build's save (forward-compat).
  final Map<String, Object?> unknownKeys;

  static const Set<String> _known = {
    'theme',
    'view',
    'sort_per_view',
    'show_completed',
    'excluded_lists',
    'list_order',
    'onboarding_seen',
    'hide_completed_subtasks',
    'haptics',
    'window_size',
    'sidebar_width',
    'detail_fraction',
  };

  Prefs copyWith({
    String? theme,
    String? view,
    Map<String, String>? sortPerView,
    bool? showCompleted,
    List<String>? excludedLists,
    List<String>? listOrder,
    bool? onboardingSeen,
    bool? hideCompletedSubtasks,
    bool? haptics,
    WindowSize? windowSize,
    double? sidebarWidth,
    double? detailFraction,
  }) => Prefs(
    theme: theme ?? this.theme,
    view: view ?? this.view,
    sortPerView: sortPerView ?? this.sortPerView,
    showCompleted: showCompleted ?? this.showCompleted,
    excludedLists: excludedLists ?? this.excludedLists,
    listOrder: listOrder ?? this.listOrder,
    onboardingSeen: onboardingSeen ?? this.onboardingSeen,
    hideCompletedSubtasks: hideCompletedSubtasks ?? this.hideCompletedSubtasks,
    haptics: haptics ?? this.haptics,
    windowSize: windowSize ?? this.windowSize,
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
    detailFraction: detailFraction ?? this.detailFraction,
    unknownKeys: unknownKeys,
  );

  Map<String, Object?> toJson() => {
    ...unknownKeys,
    'theme': theme,
    'view': view,
    'sort_per_view': sortPerView,
    'show_completed': showCompleted,
    'excluded_lists': excludedLists,
    'list_order': listOrder,
    'onboarding_seen': onboardingSeen,
    'hide_completed_subtasks': hideCompletedSubtasks,
    'haptics': haptics,
    if (windowSize != null) 'window_size': windowSize!.toJson(),
    if (sidebarWidth != null) 'sidebar_width': sidebarWidth,
    if (detailFraction != null) 'detail_fraction': detailFraction,
  };

  factory Prefs.fromJson(Map<String, Object?> json) => Prefs(
    theme: json['theme'] as String? ?? 'dark',
    view: json['view'] as String? ?? 'all',
    sortPerView:
        (json['sort_per_view'] as Map?)?.cast<String, String>() ?? const {},
    showCompleted: json['show_completed'] as bool? ?? false,
    excludedLists:
        (json['excluded_lists'] as List?)?.cast<String>() ?? const [],
    listOrder: (json['list_order'] as List?)?.cast<String>() ?? const [],
    onboardingSeen: json['onboarding_seen'] as bool? ?? false,
    hideCompletedSubtasks: json['hide_completed_subtasks'] as bool? ?? false,
    haptics: json['haptics'] as bool? ?? true,
    windowSize: WindowSize.fromJson(json['window_size']),
    sidebarWidth: _positiveDouble(json['sidebar_width']),
    detailFraction: _fraction(json['detail_fraction']),
    unknownKeys: {
      for (final e in json.entries)
        if (!_known.contains(e.key)) e.key: e.value,
    },
  );

  /// A finite, strictly-positive double from disk, else `null` (a malformed
  /// pane width must fall back to the default, never crash startup).
  static double? _positiveDouble(Object? v) =>
      (v is num && v.isFinite && v > 0) ? v.toDouble() : null;

  /// A fraction strictly inside (0, 1) from disk, else `null`. A value outside
  /// the open interval could crush a pane to zero or overflow the row.
  static double? _fraction(Object? v) =>
      (v is num && v.isFinite && v > 0 && v < 1) ? v.toDouble() : null;
}

/// Durable JSON store for [Prefs] over a `prefs.json` file.
class PrefsStore {
  PrefsStore(this._path);

  final File _path;

  /// Path to the prefs file (display/debug).
  File get path => _path;

  /// Load prefs from disk, or the defaults when the file is missing or
  /// malformed (a corrupt prefs file must never block startup).
  Prefs load() {
    if (!_path.existsSync()) return const Prefs();
    try {
      final decoded = jsonDecode(_path.readAsStringSync());
      if (decoded is! Map) return const Prefs();
      return Prefs.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return const Prefs();
    } on FileSystemException {
      return const Prefs();
    }
  }

  /// Persist [prefs] durably (pretty JSON), creating the parent directory.
  void save(Prefs prefs) {
    _path.parent.createSync(recursive: true);
    _path.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(prefs.toJson()),
      flush: true,
    );
  }

  /// Convenience for the windowing seam: persist only the window size,
  /// leaving every other pref as it is on disk. Size-only (no position).
  void saveWindowSize(WindowSize size) =>
      save(load().copyWith(windowSize: size));
}
