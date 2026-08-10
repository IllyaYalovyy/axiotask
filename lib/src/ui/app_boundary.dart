// The app-level UI error boundary (T7.8) — the Dart/Flutter port of the
// reference's AppBoundary.
//
// A widget that throws during build/layout must not vanish into the framework's
// bare gray error box: a release build has no console, so an un-surfaced render
// failure is an invisible one. [installAppErrorBoundary] replaces
// `ErrorWidget.builder` so any such failure renders [AppErrorView] instead — a
// human, self-contained screen naming what went wrong. It is deliberately
// dependency-free (its own [Directionality], explicit text styles) so it
// renders even when the failure took out the ancestors a normal screen relies
// on, and it shows the error message as TEXT, so a message carrying markup is
// data, never structure.

import 'package:flutter/material.dart';

/// A self-contained "something in the UI failed" screen. Shows a heading, the
/// [message] verbatim as text, and — only when a reset is actually possible —
/// an [onRetry] button.
class AppErrorView extends StatelessWidget {
  const AppErrorView({required this.message, this.onRetry, super.key});

  /// The failure detail, rendered as literal text.
  final String message;

  /// A reset action; when null no Retry button is shown (a build-time
  /// `ErrorWidget` has nothing to reset).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1C1B1F);
    const fg = Color(0xFFE6E1E5);
    const muted = Color(0xFFCAC4D0);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: bg,
        child: Semantics(
          container: true,
          liveRegion: true,
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.error_outline,
                        size: 44,
                        color: Color(0xFFF2B8B5),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'axiotask hit a UI error',
                        style: TextStyle(
                          color: fg,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        style: const TextStyle(color: muted, fontSize: 14),
                      ),
                      if (onRetry != null) ...<Widget>[
                        const SizedBox(height: 20),
                        TextButton(
                          onPressed: onRetry,
                          child: const Text('Retry'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Route every render-time failure through [AppErrorView] instead of the
/// framework's default gray error box. Call once at startup.
void installAppErrorBoundary() {
  ErrorWidget.builder = (FlutterErrorDetails details) =>
      AppErrorView(message: details.exceptionAsString());
}
