import 'dart:io';

import 'package:toml/toml.dart';

import '../../data/auth/authorization.dart';
import '../composition/linux_read_transport.dart';

enum LinuxApplicationProfile {
  production(directoryName: 'axiotask', requiresDedicatedSubject: false),
  development(directoryName: 'axiotask-dev', requiresDedicatedSubject: true);

  const LinuxApplicationProfile({
    required this.directoryName,
    required this.requiresDedicatedSubject,
  });

  final String directoryName;
  final bool requiresDedicatedSubject;
}

final class LinuxProfileConfiguration {
  const LinuxProfileConfiguration({
    required this.google,
    required this.dedicatedAccountSubject,
    required this.path,
  });

  final LinuxReadConfiguration google;
  final AccountSubject? dedicatedAccountSubject;
  final String path;

  static Future<LinuxProfileConfiguration> load({
    required LinuxApplicationProfile profile,
    Map<String, String>? environment,
    File? file,
  }) async {
    final path =
        file?.path ?? resolvePath(profile: profile, environment: environment);
    final FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(path, followLinks: false);
    } on FileSystemException {
      throw LinuxProfileConfigurationException(
        'Configuration at $path cannot be inspected.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      throw LinuxProfileConfigurationException(
        'Configuration is missing at $path.',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw LinuxProfileConfigurationException(
        'Configuration at $path must be a regular file, not a link.',
      );
    }

    final String source;
    try {
      source = await File(path).readAsString();
    } on FileSystemException {
      throw LinuxProfileConfigurationException(
        'Configuration at $path cannot be read.',
      );
    }

    final Map<String, dynamic> document;
    try {
      document = TomlDocument.parse(source).toMap();
    } on Object {
      throw LinuxProfileConfigurationException(
        'Configuration at $path is not valid TOML.',
      );
    }

    final googleTable = document['google'];
    if (googleTable is! Map<String, dynamic>) {
      throw LinuxProfileConfigurationException(
        'Configuration at $path requires a [google] table.',
      );
    }
    final clientId = _requiredString(googleTable, 'client_id', path: path);
    if (!clientId.endsWith('.apps.googleusercontent.com')) {
      throw LinuxProfileConfigurationException(
        'Configuration at $path has an invalid google.client_id.',
      );
    }
    final clientSecret = _requiredString(
      googleTable,
      'client_secret',
      path: path,
    );

    AccountSubject? dedicatedSubject;
    if (profile.requiresDedicatedSubject) {
      dedicatedSubject = AccountSubject(
        _requiredString(googleTable, 'account_subject', path: path),
      );
    }

    return LinuxProfileConfiguration(
      google: LinuxReadConfiguration(
        clientId: clientId,
        clientSecret: clientSecret,
      ),
      dedicatedAccountSubject: dedicatedSubject,
      path: path,
    );
  }

  static String resolvePath({
    required LinuxApplicationProfile profile,
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final configuredRoot = values['XDG_CONFIG_HOME']?.trim();
    final String root;
    if (configuredRoot != null && configuredRoot.isNotEmpty) {
      if (!configuredRoot.startsWith('/')) {
        throw const LinuxProfileConfigurationException(
          'XDG_CONFIG_HOME must be an absolute path.',
        );
      }
      root = configuredRoot;
    } else {
      final home = values['HOME']?.trim();
      if (home == null || home.isEmpty || !home.startsWith('/')) {
        throw const LinuxProfileConfigurationException(
          'HOME must be an absolute path when XDG_CONFIG_HOME is unset.',
        );
      }
      root = '$home/.config';
    }
    return '$root/${profile.directoryName}/config.toml';
  }
}

final class LinuxProfileConfigurationException implements Exception {
  const LinuxProfileConfigurationException(this.message);

  final String message;

  @override
  String toString() => 'Axiotask configuration error: $message';
}

String _requiredString(
  Map<String, dynamic> table,
  String key, {
  required String path,
}) {
  final value = table[key];
  if (value is! String || value.trim().isEmpty) {
    throw LinuxProfileConfigurationException(
      'Configuration at $path requires non-empty google.$key.',
    );
  }
  return value.trim();
}
