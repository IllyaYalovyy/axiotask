// The root application widget mounted after a successful bootstrap. This is
// scaffolding: the real adaptive shell (lists, detail panel, smart views) lands
// in T2.2+. Its job today is to prove the wiring — a themed MaterialApp reading
// its instance label from the providers root — and to give the integration
// smoke test a live first frame.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Root widget. The shell content is a placeholder until T2.2.
class AxiotaskApp extends ConsumerWidget {
  const AxiotaskApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefix = ref.watch(instancePrefixProvider);
    final title = prefix == null ? 'axiotask' : 'axiotask ($prefix)';
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('axiotask is starting up.')),
      ),
    );
  }
}
