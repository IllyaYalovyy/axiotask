import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The GTK application identifier set in `linux/CMakeLists.txt`.
const String linuxApplicationIdentifier = 'io.github.IllyaYalovyy.axiotask';

/// The directory that holds the database, diagnostics and preferences.
///
/// On Linux this is always `$XDG_DATA_HOME/<application id>`. path_provider
/// would instead reuse `$XDG_DATA_HOME/axiotask` when that directory exists,
/// which is where v1.5.3 and earlier kept an incompatible `axiotask.sqlite`;
/// a new installation must never open that data. Creating the directory here
/// also makes every later path_provider lookup resolve to it.
Future<Directory> resolveApplicationSupportDirectory({
  Map<String, String>? environment,
}) async {
  if (!Platform.isLinux) return getApplicationSupportDirectory();
  final directory = linuxApplicationSupportDirectory(
    environment ?? Platform.environment,
  );
  await directory.create(recursive: true);
  return directory;
}

Directory linuxApplicationSupportDirectory(Map<String, String> environment) {
  final separator = Platform.pathSeparator;
  final dataHome = environment['XDG_DATA_HOME'];
  // The XDG specification ignores a relative XDG_DATA_HOME.
  final base = dataHome != null && dataHome.startsWith('/')
      ? dataHome
      : '${environment['HOME'] ?? ''}$separator.local${separator}share';
  return Directory('$base$separator$linuxApplicationIdentifier');
}
