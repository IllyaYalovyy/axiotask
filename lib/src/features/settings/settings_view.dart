import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/visual_tokens.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../domain/model/preferences.dart';
import '../../domain/repository/preferences_repository.dart';
import 'settings_view_model.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.preferencesRepository,
    this.diagnostics,
    super.key,
  });

  final PreferencesRepository preferencesRepository;
  final DiagnosticSink? diagnostics;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  late final SettingsViewModel _viewModel = SettingsViewModel(
    widget.preferencesRepository,
    diagnostics: widget.diagnostics,
  )..start();

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsView(viewModel: _viewModel);
}

final class SettingsView extends StatelessWidget {
  const SettingsView({required this.viewModel, super.key});

  final SettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: viewModel,
    builder: (context, _) {
      final state = viewModel.state;
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: state.isLoading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, constraints) => Center(
                  child: SizedBox(
                    width: constraints.maxWidth.clamp(0, 760).toDouble(),
                    child: ListView(
                      key: const Key('settings-scroll'),
                      padding: EdgeInsets.all(
                        Theme.of(context).axiotaskTokens.horizontalInset,
                      ),
                      children: <Widget>[
                        Text(
                          'Appearance',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Choose how Axiotask looks on this device.',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (state.failureMessage case final message?) ...[
                          const SizedBox(height: 16),
                          MaterialBanner(
                            key: const Key('settings-failure'),
                            leading: const Icon(Icons.warning_amber_outlined),
                            content: Semantics(
                              liveRegion: true,
                              child: Text(message),
                            ),
                            actions: <Widget>[
                              TextButton(
                                onPressed: viewModel.clearFailure,
                                child: const Text('Dismiss'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 28),
                        _PreferenceHeading(
                          title: 'Theme',
                          description:
                              'Follow the desktop setting or choose a fixed '
                              'light or dark appearance.',
                        ),
                        const SizedBox(height: 8),
                        RadioGroup<ThemePreference>(
                          groupValue: state.preferences.theme,
                          onChanged: (value) {
                            if (value != null && !state.isSaving) {
                              unawaited(viewModel.setTheme(value));
                            }
                          },
                          child: Column(
                            children: <Widget>[
                              for (final preference in ThemePreference.values)
                                _PreferenceRadio<ThemePreference>(
                                  key: Key('settings-theme-${preference.name}'),
                                  value: preference,
                                  label: _themeLabel(preference),
                                  semanticsLabel:
                                      '${_themeLabel(preference)} theme',
                                  selected:
                                      state.preferences.theme == preference,
                                  enabled: !state.isSaving,
                                  autofocus:
                                      state.preferences.theme == preference,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        const _PreferenceHeading(
                          title: 'Density',
                          description:
                              'Compact reduces spacing while preserving '
                              'desktop pointer and keyboard targets.',
                        ),
                        const SizedBox(height: 8),
                        RadioGroup<DensityPreference>(
                          groupValue: state.preferences.density,
                          onChanged: (value) {
                            if (value != null && !state.isSaving) {
                              unawaited(viewModel.setDensity(value));
                            }
                          },
                          child: Column(
                            children: <Widget>[
                              for (final preference in DensityPreference.values)
                                _PreferenceRadio<DensityPreference>(
                                  key: Key(
                                    'settings-density-${preference.name}',
                                  ),
                                  value: preference,
                                  label: _densityLabel(preference),
                                  semanticsLabel:
                                      '${_densityLabel(preference)} density',
                                  selected:
                                      state.preferences.density == preference,
                                  enabled: !state.isSaving,
                                ),
                            ],
                          ),
                        ),
                        if (state.isSaving) ...<Widget>[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(
                            key: Key('settings-saving'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
      );
    },
  );
}

final class _PreferenceHeading extends StatelessWidget {
  const _PreferenceHeading({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(description, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

final class _PreferenceRadio<T> extends StatelessWidget {
  const _PreferenceRadio({
    required this.value,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.enabled,
    this.autofocus = false,
    super.key,
  });

  final T value;
  final String label;
  final String semanticsLabel;
  final bool selected;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$semanticsLabel${selected ? ', selected' : ''}',
    checked: selected,
    inMutuallyExclusiveGroup: true,
    child: ExcludeSemantics(
      child: RadioListTile<T>(
        value: value,
        autofocus: autofocus,
        enabled: enabled,
        title: Text(label),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

String _themeLabel(ThemePreference preference) => switch (preference) {
  ThemePreference.system => 'System',
  ThemePreference.light => 'Light',
  ThemePreference.dark => 'Dark',
};

String _densityLabel(DensityPreference preference) => switch (preference) {
  DensityPreference.standard => 'Standard',
  DensityPreference.compact => 'Compact',
};
