import 'package:axiotask/src/domain/repository/external_link_launcher.dart';

final class FakeExternalLinkLauncher implements ExternalLinkLauncher {
  FakeExternalLinkLauncher({this.succeeds = true});

  final bool succeeds;
  final List<Uri> launched = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    launched.add(uri);
    return succeeds;
  }
}
