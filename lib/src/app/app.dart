// The root application widget mounted after a successful bootstrap.
//
// It wires the three cross-cutting shell concerns from T2.2: the go_router
// config (the adaptive shell lives under it), the Material 3 light/dark themes,
// and the `theme` pref that selects between them. The desktop window title is
// handled inside the shell (see AppShell) via the window-title seam.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/theme.dart';
import 'providers.dart';

/// Root widget: a router-driven, themed [MaterialApp].
class AxiotaskApp extends ConsumerWidget {
  const AxiotaskApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefix = ref.watch(instancePrefixProvider);
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      // Base app title (task switcher / accessibility). The live desktop window
      // title ("<View> — axiotask") is set by the shell per view.
      title: prefix == null ? 'axiotask' : 'axiotask ($prefix)',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
