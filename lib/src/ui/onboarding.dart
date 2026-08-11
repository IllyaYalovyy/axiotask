// The first-launch welcome intro — the surviving half of the reference's
// Cheatsheet component (the keyboard-shortcut overlay itself dies with the
// keyboard layer; this onboarding MOMENT is worth keeping). It teaches the one
// gesture that matters on day one: capture a task in the quick-add field, and
// end the text with a date to schedule it.
//
// Shown once, on an empty workspace, until dismissed — the gating lives in the
// shell (`onboardingSeen` pref). This widget is a pure presentation surface: it
// takes an [onDismiss] callback and nothing else, so it is trivially testable
// and reusable. Visuals are fresh Material 3 (Q3), not a pixel port.

import 'package:flutter/material.dart';

/// A full-surface welcome overlay shown on first launch. [onDismiss] fires when
/// the user taps "Start using axiotask" (the shell then persists onboardingSeen).
class OnboardingIntro extends StatelessWidget {
  const OnboardingIntro({required this.onDismiss, super.key});

  /// Dismiss the intro (marks it seen so it never returns).
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    // A scrim over the whole app so the welcome reads as a modal moment. The
    // barrier is inert (no dismiss-on-tap): the intro is left only via its
    // explicit button, matching the reference's "Start using axiotask".
    return Material(
      key: const Key('onboarding-intro'),
      color: colors.scrim.withValues(alpha: 0.6),
      // Centered when it fits, scrollable when it doesn't (F19 #198): at a large
      // system text scale (2.0) the fixed card would overflow a short phone
      // viewport and throw a RenderFlex error. A scroll view whose child is at
      // least the viewport height keeps the card centered normally and lets it
      // scroll — never clip — when the enlarged text makes it taller than the
      // screen.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.checklist_rounded,
                          size: 40,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Welcome to axiotask',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Capture a task in the quick-add field at the top. End the '
                          'text with a date — like “tomorrow” or 2026-08-03 — and '
                          'axiotask schedules it for you automatically.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            key: const Key('onboarding-dismiss'),
                            onPressed: onDismiss,
                            child: const Text('Start using axiotask'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
