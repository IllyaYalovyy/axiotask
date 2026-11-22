import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/app_destinations.dart';
import '../../app/haptics.dart';
import '../../app/visual_tokens.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../domain/model/preferences.dart';
import '../../domain/repository/preferences_repository.dart';
import 'settings_view_model.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.preferencesRepository,
    this.diagnostics,
    this.destinations = const AppDestinations(),
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
    super.key,
  });

  final PreferencesRepository preferencesRepository;
  final DiagnosticSink? diagnostics;
  final AppDestinations destinations;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;

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
  Widget build(BuildContext context) => SettingsView(
    viewModel: _viewModel,
    destinations: widget.destinations,
    accountBackupBuilder: widget.accountBackupBuilder,
    localDataRecoveryBuilder: widget.localDataRecoveryBuilder,
  );
}

final class SettingsView extends StatelessWidget {
  const SettingsView({
    required this.viewModel,
    this.destinations = const AppDestinations(),
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
    super.key,
  });

  final SettingsViewModel viewModel;
  final AppDestinations destinations;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;

  void _open(BuildContext context, WidgetBuilder builder) {
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: builder));
  }

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
                        const SizedBox(height: 28),
                        const _PreferenceHeading(
                          title: 'Task details',
                          description:
                              'How subtasks are presented when a task is '
                              'opened.',
                        ),
                        _PreferenceSwitch(
                          key: const Key('settings-collapse-completed'),
                          title: 'Collapse completed subtasks',
                          subtitle:
                              'Finished subtasks start hidden behind a '
                              '"Show completed" control in task details.',
                          value: state.preferences.collapseCompletedSubtasks,
                          enabled: !state.isSaving,
                          onChanged: (value) => unawaited(
                            viewModel.setToggle(
                              DeviceToggle.collapseCompletedSubtasks,
                              value,
                            ),
                          ),
                        ),
                        // Haptics exist only where there is a haptic engine
                        // to drive; on a desktop this switch would change
                        // nothing, so it is not shown.
                        if (supportsHaptics(Theme.of(context).platform)) ...[
                          const SizedBox(height: 28),
                          const _PreferenceHeading(
                            title: 'Feedback',
                            description: 'Touch feedback on this device.',
                          ),
                          _PreferenceSwitch(
                            key: const Key('settings-haptics'),
                            title: 'Haptics',
                            subtitle:
                                'A short vibration when a task is completed, '
                                'selected, rescheduled, swiped or deleted.',
                            value: state.preferences.haptics,
                            enabled: !state.isSaving,
                            onChanged: (value) => unawaited(
                              viewModel.setToggle(DeviceToggle.haptics, value),
                            ),
                          ),
                        ],
                        const SizedBox(height: 28),
                        const _PreferenceHeading(
                          title: 'Sync',
                          description:
                              'How this device exchanges changes with Google '
                              'Tasks.',
                        ),
                        _PreferenceSwitch(
                          key: const Key('settings-auto-sync-startup'),
                          title: 'Auto-sync on startup',
                          subtitle:
                              'Synchronize automatically when Axiotask '
                              'starts. Refresh and local edits still '
                              'synchronize when this is off.',
                          value: state.preferences.autoSyncOnStartup,
                          enabled: !state.isSaving,
                          onChanged: (value) => unawaited(
                            viewModel.setToggle(
                              DeviceToggle.autoSyncOnStartup,
                              value,
                            ),
                          ),
                        ),
                        if (destinations.syncActivity case final builder?)
                          _SettingsLink(
                            key: const Key('settings-sync-activity'),
                            icon: Icons.history,
                            title: 'Sync activity',
                            subtitle:
                                'Every synchronization run and its result.',
                            onTap: () => _open(context, builder),
                          ),
                        if (destinations.account != null ||
                            accountBackupBuilder != null ||
                            localDataRecoveryBuilder != null) ...[
                          const SizedBox(height: 28),
                          const _PreferenceHeading(
                            title: 'Account and data',
                            description:
                                'Your Google connection and the copy of your '
                                'tasks on this device.',
                          ),
                          if (destinations.account case final builder?)
                            _SettingsLink(
                              key: const Key('settings-account'),
                              icon: Icons.account_circle_outlined,
                              title: 'Account',
                              subtitle: 'Sign out or switch Google account.',
                              onTap: () => _open(context, builder),
                            ),
                          if (accountBackupBuilder case final builder?)
                            _SettingsLink(
                              key: const Key('settings-account-backup'),
                              icon: Icons.save_alt_outlined,
                              title: 'Account backup',
                              subtitle:
                                  'Export or restore a complete backup file.',
                              onTap: () => _open(context, builder),
                            ),
                          if (localDataRecoveryBuilder case final builder?)
                            _SettingsLink(
                              key: const Key('settings-local-data-recovery'),
                              icon: Icons.settings_backup_restore,
                              title: 'Local data recovery',
                              subtitle:
                                  'Rebuild this device from Google Tasks.',
                              onTap: () => _open(context, builder),
                            ),
                        ],
                        if (destinations.about != null ||
                            destinations.supportProject != null) ...[
                          const SizedBox(height: 28),
                          const _PreferenceHeading(
                            title: 'About',
                            description: 'Version and project information.',
                          ),
                          if (destinations.about case final builder?)
                            _SettingsLink(
                              key: const Key('settings-about'),
                              icon: Icons.info_outline,
                              title: 'About Axiotask',
                              subtitle: 'Version, license and source code.',
                              onTap: () => _open(context, builder),
                            ),
                          if (destinations.supportProject case final support?)
                            _SettingsLink(
                              key: const Key('settings-support-project'),
                              icon: Icons.favorite_outline,
                              title: 'Support the project',
                              subtitle:
                                  'Opens the sponsorship page in your browser.',
                              onTap: support,
                            ),
                        ],
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

final class _PreferenceSwitch extends StatelessWidget {
  const _PreferenceSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: enabled ? onChanged : null,
  );
}

final class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
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
