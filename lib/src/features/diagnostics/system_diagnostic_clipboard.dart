import 'package:flutter/services.dart';

import '../../core/diagnostics/diagnostics.dart';

final class SystemDiagnosticClipboard implements DiagnosticClipboardPort {
  const SystemDiagnosticClipboard();

  @override
  Future<void> writeText(String value) =>
      Clipboard.setData(ClipboardData(text: value));
}
