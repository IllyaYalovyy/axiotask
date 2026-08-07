// The startup-error screen — the Dart/Flutter port of `show_startup_error`.
//
// A fatal startup failure (the store's `WipeAborted` fail-open, or any DB open
// error) must not vanish into a dead frame or a hung "Loading…" — the release
// build has no console. Instead the bootstrap mounts THIS as the whole app: a
// minimal, self-contained screen that tells the user why axiotask refused to
// start. No providers, no store, no sync are wired behind it — it is the app
// until the process is closed.
//
// It carries only a plain string message, so a `StoreError`'s text (quotes,
// newlines, paths) renders safely as data, never as markup.

import 'package:flutter/material.dart';

/// A standalone [MaterialApp] that shows a single fatal [message]. Used as the
/// root widget when bootstrap cannot bring up the real app.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({required this.message, super.key});

  /// The fatal error, shown verbatim.
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'axiotask — startup error',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: StartupErrorScreen(message: message),
    );
  }
}

/// The error content itself, without the [MaterialApp] wrapper — kept separate
/// so it can be embedded and widget-tested in isolation.
class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({required this.message, super.key});

  /// The fatal error, shown verbatim.
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        // Scrollable so a long error message at a large text scale on a small
        // screen never overflows off the bottom (this screen IS the whole app).
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'axiotask could not start',
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(message, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
