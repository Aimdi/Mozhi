import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// App locations this feature links to. They mirror `AppRoutes` and are
/// kept here so the feature does not import the router (which imports this
/// feature's page).
abstract final class ImageTranslateLinks {
  static const translator = '/translate';
  static const providers = '/settings/providers';
  static const instances = '/settings/instances';
}

/// Copies [text] and confirms with a snackbar.
Future<void> copyImageTranslation(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = context.l10n.commonCopied;
  await Clipboard.setData(ClipboardData(text: text));
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
