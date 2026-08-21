import 'package:flutter/material.dart';

import '../domain/model/preferences.dart';
import '../domain/repository/preferences_repository.dart';
import '../features/onboarding/onboarding_view.dart';
import '../features/onboarding/onboarding_view_model.dart';
import '../features/tasks/tasks_view_model.dart';
import 'adaptive_shell.dart';
import 'visual_tokens.dart';

class AxiotaskApp extends StatefulWidget {
  const AxiotaskApp({
    required this.viewModel,
    this.preferencesRepository,
    this.diagnosticsBuilder,
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
    super.key,
  });

  final TasksViewModel viewModel;
  final PreferencesRepository? preferencesRepository;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;

  @override
  State<AxiotaskApp> createState() => _AxiotaskAppState();
}

final class _AxiotaskAppState extends State<AxiotaskApp> {
  OnboardingViewModel? _presentation;

  @override
  void initState() {
    super.initState();
    _openPresentation();
  }

  @override
  void didUpdateWidget(covariant AxiotaskApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferencesRepository != widget.preferencesRepository ||
        oldWidget.viewModel.preferencesRepository !=
            widget.viewModel.preferencesRepository) {
      _presentation?.dispose();
      _openPresentation();
    }
  }

  void _openPresentation() {
    final repository =
        widget.preferencesRepository ?? widget.viewModel.preferencesRepository;
    if (repository == null) return;
    _presentation = OnboardingViewModel(
      repository,
      diagnostics: widget.viewModel.diagnostics,
    )..start();
  }

  @override
  void dispose() {
    _presentation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presentation = _presentation;
    return AnimatedBuilder(
      animation: presentation ?? Listenable.merge(const <Listenable>[]),
      builder: (context, _) {
        final preferences =
            presentation?.state.preferences ??
            const DevicePreferences.defaults();
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Axiotask',
          theme: axiotaskTheme(Brightness.light, preferences.density),
          darkTheme: axiotaskTheme(Brightness.dark, preferences.density),
          themeMode: switch (preferences.theme) {
            ThemePreference.system => ThemeMode.system,
            ThemePreference.light => ThemeMode.light,
            ThemePreference.dark => ThemeMode.dark,
          },
          home: Stack(
            children: <Widget>[
              ExcludeSemantics(
                excluding: presentation?.state.isVisible ?? false,
                child: AdaptiveShell(
                  viewModel: widget.viewModel,
                  diagnosticsBuilder: widget.diagnosticsBuilder,
                  accountBackupBuilder: widget.accountBackupBuilder,
                  localDataRecoveryBuilder: widget.localDataRecoveryBuilder,
                ),
              ),
              if (presentation case final viewModel?
                  when viewModel.state.isVisible)
                Positioned.fill(
                  child: OnboardingView(
                    onDismiss: viewModel.dismiss,
                    isSaving: viewModel.state.isSaving,
                    failureMessage: viewModel.state.failureMessage,
                  ),
                ),
              if (presentation case final viewModel?
                  when !viewModel.state.isVisible &&
                      viewModel.state.failureMessage != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: SafeArea(
                    top: false,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Material(
                          elevation: 3,
                          color: Theme.of(context).colorScheme.surface,
                          child: MaterialBanner(
                            key: const Key('onboarding-persistence-notice'),
                            content: Semantics(
                              liveRegion: true,
                              child: Text(viewModel.state.failureMessage!),
                            ),
                            actions: <Widget>[
                              TextButton(
                                onPressed: viewModel.clearFailure,
                                child: const Text('Dismiss notice'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
