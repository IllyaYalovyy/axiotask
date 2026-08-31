// Shared test wiring for the one feedback surface (F19 #198). Undo/info toasts
// route through the app-wide [ToastController] and render in the [ToastOverlay]
// that app.dart mounts above the Navigator. A widget test that drives a surface
// which raises a toast (a delete undo, a landing "View", a #164 cascade) must
// mount that same overlay or the toast has nowhere to paint.
//
// Use as `MaterialApp(builder: wrapWithToast, home: …)`: the builder runs BELOW
// the test's ProviderScope, so its [Consumer] reads the very
// `toastControllerProvider` the surface under test writes to — the same
// controller instance, exactly as in production.

import 'package:axiotask/src/ui/haptics.dart';
import 'package:axiotask/src/ui/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A `MaterialApp.builder` that paints the real [ToastOverlay] over [child],
/// bound to the ambient [toastControllerProvider].
Widget wrapWithToast(BuildContext context, Widget? child) => Consumer(
  builder: (context, ref, _) => ToastOverlay(
    controller: ref.read(toastControllerProvider),
    haptics: ref.watch(hapticsProvider),
    child: child ?? const SizedBox.shrink(),
  ),
);
