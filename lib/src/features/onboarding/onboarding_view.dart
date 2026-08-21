import 'package:flutter/material.dart';

final class OnboardingView extends StatelessWidget {
  const OnboardingView({
    required this.onDismiss,
    this.isSaving = false,
    this.failureMessage,
    super.key,
  });

  final Future<void> Function() onDismiss;
  final bool isSaving;
  final String? failureMessage;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final intro = <Widget>[
      Text(
        'Welcome to Axiotask',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      Text(
        'A focused Google Tasks client that keeps connection and sync status clear.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 24),
    ];
    final points = <Widget>[
      _OnboardingPoint(
        icon: Icons.link,
        title: 'Connect to Google Tasks',
        body:
            'Use Connect in the sync status area to authorize your Google Tasks account.',
      ),
      _OnboardingPoint(
        icon: Icons.verified_outlined,
        title: 'Sync stays truthful',
        body:
            'Connected does not mean synced. Axiotask shows when it is checking, synced, pending, or needs attention.',
      ),
      _OnboardingPoint(
        icon: Icons.cloud_off_outlined,
        title: 'Work through an outage',
        body:
            'Cached tasks stay available offline. New changes remain pending until Google can confirm them.',
      ),
      _OnboardingPoint(
        icon: Icons.add_task_outlined,
        title: 'Capture without breaking flow',
        body:
            'Use Add task for a quick capture. Your chosen Google list stays visible before you save.',
      ),
      _OnboardingPoint(
        icon: Icons.settings_backup_restore_outlined,
        title: 'Recover safely',
        body:
            'Recovery is available from the app header and explains what it can and cannot change before you continue.',
      ),
    ];
    return Semantics(
      container: true,
      label: 'Welcome to Axiotask onboarding',
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: SingleChildScrollView(
                key: const Key('onboarding-scroll'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: intro,
                            ),
                          ),
                          const SizedBox(width: 32),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: points,
                            ),
                          ),
                        ],
                      )
                    else ...<Widget>[...intro, ...points],
                    if (failureMessage case final message?) ...<Widget>[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          message,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Semantics(
                        label: 'Finish onboarding',
                        button: true,
                        child: FilledButton(
                          autofocus: true,
                          onPressed: isSaving ? null : onDismiss,
                          style: FilledButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimary,
                          ),
                          child: isSaving
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Start using Axiotask'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _OnboardingPoint extends StatelessWidget {
  const _OnboardingPoint({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          icon,
          semanticLabel: '',
          color: Theme.of(context).colorScheme.onSurface,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
