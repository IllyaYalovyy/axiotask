import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/repository/external_link_launcher.dart';

typedef ExternalUrlStarter = Future<bool> Function(Uri uri);

final class UrlLauncherAdapter implements ExternalLinkLauncher {
  const UrlLauncherAdapter({this.starter = _launchExternal});

  final ExternalUrlStarter starter;

  @override
  Future<bool> launch(Uri uri) async {
    try {
      return await starter(uri);
    } on PlatformException {
      return false;
    }
  }
}

Future<bool> _launchExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
