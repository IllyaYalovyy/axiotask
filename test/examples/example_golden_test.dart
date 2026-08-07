// EXAMPLE — golden layer (pixel snapshot via alchemist).
//
// Template for golden tests. The golden PNGs live beside this file under
// goldens/ and are byte-compared on every `flutter test`. Regenerating them is
// a DELIBERATE, ISOLATED act — run `flutter test --update-goldens` only in a
// dedicated toolchain/design-bump commit, NEVER folded into a feature change
// (see TESTING.md §"Golden discipline"). A feature task that changes a golden
// must fail loudly, not silently rewrite the baseline.
import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';

void main() {
  goldenTest(
    'example card renders its label',
    fileName: 'example_card',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(name: 'default', child: const _ExampleCard()),
      ],
    ),
  );
}

class _ExampleCard extends StatelessWidget {
  const _ExampleCard();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B1B1F),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'axiotask',
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            color: Color(0xFFE6E1E5),
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
