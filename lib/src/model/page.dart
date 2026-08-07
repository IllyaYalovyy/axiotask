// One page of a paginated list response — the Dart port of `model.rs`'s
// `Page<T>`.

/// One page of a paginated list response.
class Page<T> {
  const Page({required this.items, this.nextPageToken});

  /// The items in this page.
  final List<T> items;

  /// Continuation token, if more pages exist.
  final String? nextPageToken;
}
