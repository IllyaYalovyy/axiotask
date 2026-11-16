import 'dart:io';

import 'runner.dart';

/// Runs a named manifest subset, for example the 17-case `baseline`.
Future<void> main(List<String> arguments) async {
  final RunnerOptions options;
  try {
    options = RunnerOptions.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(64);
  }
  exit(await runRegression(options, runProcess));
}
