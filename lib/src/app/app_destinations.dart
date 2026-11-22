import 'package:material_ui/material_ui.dart';

/// Application-level places the shell offers beside the task workspace.
///
/// Each is optional so focused tests can build a shell without them, but the
/// shipped product supplies all of them; the must-have feature contract
/// (`test/contract/`) fails when one stops being reachable.
final class AppDestinations {
  const AppDestinations({
    this.about,
    this.syncActivity,
    this.account,
    this.supportProject,
  });

  /// Version and project information.
  final WidgetBuilder? about;

  /// The per-run synchronization history.
  final WidgetBuilder? syncActivity;

  /// Sign-out and account switching.
  final WidgetBuilder? account;

  /// Opens the project's sponsorship page outside the application.
  final VoidCallback? supportProject;
}
