// Colour metrics for tests that assert a palette is LEGIBLE and DISTINGUISHABLE
// rather than merely "some colour was set".
//
// Two questions come up whenever a scheme role is chosen for meaning:
//
//   • can the user READ it on the surface behind it? → [contrastRatio] (WCAG
//     2.x relative-luminance ratio; 4.5:1 is the AA bar for body text),
//   • can the user TELL IT APART from the other colours in the same vocabulary?
//     → [perceptualDistance] (CIE76 ΔE in CIELAB — sRGB distance is useless
//     here: two reds far apart in RGB can be the same colour to the eye).
//
// A `!=` assertion answers neither: `error` and `tertiary` in the dark scheme
// are different Color values and still read as one colour (#242).

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// The WCAG 2.x contrast ratio between two OPAQUE colours (1.0 – 21.0).
///
/// Both colours must be opaque; a translucent colour has no defined luminance
/// until it is composited, so resolve it against its background first.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// The CIE76 ΔE between two colours — roughly "how far apart the eye judges
/// them". ~2.3 is the just-noticeable difference; the values this app asserts
/// are far larger, because "attention" and "alarm" must be told apart at a
/// glance, in a 13px badge, without staring.
double perceptualDistance(Color a, Color b) {
  final la = _toLab(a);
  final lb = _toLab(b);
  return math.sqrt(
    math.pow(la[0] - lb[0], 2) +
        math.pow(la[1] - lb[1], 2) +
        math.pow(la[2] - lb[2], 2),
  );
}

/// sRGB → CIELAB (D65), the space ΔE is defined in.
List<double> _toLab(Color c) {
  double linear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  final r = linear(c.r);
  final g = linear(c.g);
  final b = linear(c.b);
  // D65 white point.
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;

  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;

  final fx = f(x);
  final fy = f(y);
  final fz = f(z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
