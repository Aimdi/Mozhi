import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';

/// App locations this feature links to. They mirror `AppRoutes` and are
/// kept here so the feature does not import the router (which imports this
/// feature's page).
abstract final class ImageTranslateLinks {
  static const translator = '/translate';
  static const providers = '/settings/providers';
  static const instances = '/settings/instances';
}

/// Copies [text] (marked as sensitive, see [copyText]) and confirms with a
/// snackbar, unless the system confirms copies itself (Android 13+).
Future<void> copyImageTranslation(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = context.l10n.commonCopied;
  await copyText(text);
  if (systemShowsCopyConfirmation) return;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
