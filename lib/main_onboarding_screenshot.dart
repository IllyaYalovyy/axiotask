import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/app/visual_tokens.dart';
import 'src/domain/model/preferences.dart';
import 'src/features/onboarding/onboarding_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OnboardingScreenshotSequence());
}

final class _OnboardingScreenshotSequence extends StatefulWidget {
  const _OnboardingScreenshotSequence();

  @override
  State<_OnboardingScreenshotSequence> createState() =>
      _OnboardingScreenshotSequenceState();
}

final class _OnboardingScreenshotSequenceState
    extends State<_OnboardingScreenshotSequence> {
  final GlobalKey _boundaryKey = GlobalKey();
  var _dark = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _capture() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      await _settleFrames();
      await _write(output, 'onboarding-light.png');
      setState(() => _dark = true);
      await _settleFrames();
      await _write(output, 'onboarding-dark.png');
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Synthetic onboarding capture failed: $error');
      exit(1);
    }
  }

  Future<void> _write(Directory output, String name) async {
    final boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) throw StateError('PNG encoding failed.');
    await File('${output.path}/$name').writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
  }

  Future<void> _settleFrames() async {
    await Future<void>.delayed(Duration.zero);
    for (var count = 0; count < 3; count += 1) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      themeAnimationDuration: Duration.zero,
      theme: axiotaskTheme(Brightness.light, DensityPreference.standard),
      darkTheme: axiotaskTheme(Brightness.dark, DensityPreference.standard),
      home: const OnboardingView(onDismiss: _dismiss),
    ),
  );
}

Future<void> _dismiss() async {}
