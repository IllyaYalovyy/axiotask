// Opening an external URL in the platform browser — the Dart analog of the
// reference's Tauri `open_url` command. The task row's link badge (and, in T7.5,
// "Open in Google Tasks") calls this. It is a single seam so tests override it
// (via [urlOpenerProvider]) instead of hitting the url_launcher platform
// channel, and so a future policy (confirm-before-open, redaction) has one place
// to live.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the platform's default browser. A malformed or unlaunchable
/// URL is swallowed (the badge is best-effort — a bad link must never crash the
/// list), mirroring the reference's fire-and-forget `open_url`.
typedef UrlOpener = Future<void> Function(String url);

/// The default opener — hands the URL to url_launcher in an external app.
Future<void> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The opener the UI uses; overridden in tests to record calls without touching
/// the platform channel.
final urlOpenerProvider = Provider<UrlOpener>((ref) => openExternalUrl);
