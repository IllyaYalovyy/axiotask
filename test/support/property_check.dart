/// The single point through which the test suite touches `kiri_check`.
///
/// Everything property-testing goes through this facade — no test imports
/// `package:kiri_check` directly. Two reasons: the library is pinned and
/// mid-evolution (one file to change if it is ever swapped), and its `forAll`
/// defaults to a *random* seed, which would make property tests flaky. This
/// facade re-exports the whole surface EXCEPT `forAll`, which it replaces with
/// a wrapper that defaults to a fixed [kDefaultPropertySeed] so a failing
/// example is reproducible.
library;

import 'dart:async';

import 'package:kiri_check/kiri_check.dart' as kiri;

export 'package:kiri_check/kiri_check.dart' hide forAll;

/// Fixed default seed for property tests, so a counterexample reproduces
/// verbatim on the next run. Override per-call only to reproduce a specific
/// reported failure.
const int kDefaultPropertySeed = 20260807;

/// Deterministic [kiri.forAll]: identical to the upstream function but seeded
/// by default. Use inside a `property(...)` body.
void forAll<T>(
  kiri.Arbitrary<T> arbitrary,
  FutureOr<void> Function(T) block, {
  int seed = kDefaultPropertySeed,
  int? maxExamples,
  int? maxShrinkingTries,
  kiri.EdgeCasePolicy? edgeCasePolicy,
}) {
  kiri.forAll<T>(
    arbitrary,
    block,
    seed: seed,
    maxExamples: maxExamples,
    maxShrinkingTries: maxShrinkingTries,
    edgeCasePolicy: edgeCasePolicy,
  );
}
