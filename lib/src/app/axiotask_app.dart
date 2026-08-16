import 'package:flutter/material.dart';

import '../features/tasks/tasks_view_model.dart';
import 'adaptive_shell.dart';

class AxiotaskApp extends StatelessWidget {
  const AxiotaskApp({
    required this.viewModel,
    this.diagnosticsBuilder,
    this.accountBackupBuilder,
    super.key,
  });

  final TasksViewModel viewModel;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? accountBackupBuilder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Axiotask',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: AdaptiveShell(
        viewModel: viewModel,
        diagnosticsBuilder: diagnosticsBuilder,
        accountBackupBuilder: accountBackupBuilder,
      ),
    );
  }
}
