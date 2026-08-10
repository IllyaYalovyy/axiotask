// URL detection for the task row — the Dart port of TaskRow.svelte's
// `extractUrls`. A task whose title or notes contains an http/https link gets a
// tappable link badge in its metadata row; this is the pure logic that decides
// which links exist and in what order (title first, then notes), independent of
// any widget so it is unit-testable on its own.
//
// The pattern matches the reference exactly: an http/https scheme, then any run
// of non-space characters up to (but not including) the closing punctuation
// `)`, `>`, `]` — so a link wrapped in prose (`(https://x)`) opens the bare URL.

/// Every http/https URL in [text], in order, or an empty list when [text] is
/// null/blank or contains none. Ports `/https?:\/\/[^\s)>\]]+/g`.
List<String> extractUrls(String? text) {
  if (text == null || text.isEmpty) return const [];
  return _urlPattern
      .allMatches(text)
      .map((m) => m.group(0)!)
      .toList(growable: false);
}

/// The URLs a task exposes: those in its [title] first, then those in its
/// [notes]. The row's link badge opens the first of these.
List<String> urlsForTask({required String title, String? notes}) => [
  ...extractUrls(title),
  ...extractUrls(notes),
];

final RegExp _urlPattern = RegExp(r'https?://[^\s)>\]]+');
