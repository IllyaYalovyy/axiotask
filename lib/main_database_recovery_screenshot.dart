import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/app/app_bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _DatabaseRecoveryScreenshot());
}

final class _DatabaseRecoveryScreenshot extends StatefulWidget {
  const _DatabaseRecoveryScreenshot();

  @override
  State<_DatabaseRecoveryScreenshot> createState() =>
      _DatabaseRecoveryScreenshotState();
}

final class _DatabaseRecoveryScreenshotState
    extends State<_DatabaseRecoveryScreenshot> {
  final GlobalKey _boundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _capture() async {
    try {
      for (var frame = 0; frame < 3; frame += 1) {
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
      final boundary =
          _boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) throw StateError('PNG encoding failed.');
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      await File('${output.path}/database-recovery.png').writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Synthetic recovery screenshot capture failed: $error');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _boundaryKey,
      child: const DatabaseRecoveryApp(opening: false, retryOpen: _noop),
    );
  }
}

void _noop() {}
