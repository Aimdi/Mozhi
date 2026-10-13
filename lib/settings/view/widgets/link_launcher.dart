import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens external links (privacy-friendly: always in the external browser).
abstract final class LinkLauncher {
  /// Replaceable in tests.
  @visibleForTesting
  static Future<bool> Function(Uri uri) launcher = _defaultLauncher;

  static Future<bool> _defaultLauncher(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// Opens [uri]; shows a snackbar when no app can handle it.
  static Future<void> open(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = context.l10n.settingsLinkOpenFailed;
    var opened = false;
    try {
      opened = await launcher(uri);
    } on Object {
      opened = false;
    }
    if (!opened) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
