import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/visual_tokens.dart';

/// Version and project information, with the way to support the project.
final class AboutPage extends StatelessWidget {
  const AboutPage({
    required this.version,
    this.onSupportProject,
    this.onOpenSourceCode,
    super.key,
  });

  /// The release version name, without a leading `v`.
  final String version;
  final VoidCallback? onSupportProject;
  final VoidCallback? onOpenSourceCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: SizedBox(
            width: constraints.maxWidth.clamp(0, 760).toDouble(),
            child: ListView(
              key: const Key('about-scroll'),
              padding: EdgeInsets.all(theme.axiotaskTokens.horizontalInset),
              children: <Widget>[
                Text('Axiotask', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  'A fast, local-first client for Google Tasks.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 20),
                Semantics(
                  label: 'Version $version',
                  child: ExcludeSemantics(
                    child: ListTile(
                      key: const Key('about-version'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tag),
                      title: const Text('Version'),
                      subtitle: Text('v$version'),
                    ),
                  ),
                ),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.gavel_outlined),
                  title: Text('License'),
                  subtitle: Text('GNU General Public License v3.0'),
                ),
                ListTile(
                  key: const Key('about-licenses'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.article_outlined),
                  title: const Text('Open-source licenses'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Axiotask',
                    applicationVersion: 'v$version',
                  ),
                ),
                if (onOpenSourceCode case final open?)
                  ListTile(
                    key: const Key('about-source-code'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.code),
                    title: const Text('Source code'),
                    subtitle: const Text('github.com/IllyaYalovyy/axiotask'),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: open,
                  ),
                if (onSupportProject case final support?) ...<Widget>[
                  const SizedBox(height: 20),
                  Text(
                    'Support the project',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Axiotask is free and has no ads or tracking. If it is '
                    'useful to you, a donation helps keep it maintained.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.icon(
                      key: const Key('about-support-project'),
                      onPressed: support,
                      icon: const Icon(Icons.favorite_outline),
                      label: const Text('Donate'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [uri] outside the application and tells the user when the system
/// refused, since nothing else on screen would change.
void openExternalPage(
  BuildContext context,
  Future<bool> Function(Uri uri) launch,
  Uri uri,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(
    launch(uri).then((opened) {
      if (opened || messenger == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open $uri. Open it in a browser.')),
      );
    }),
  );
}
