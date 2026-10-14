import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Replaces the current snack bar with [message] and an Undo action that
/// calls [onUndo]. Does nothing without a [ScaffoldMessenger].
///
/// Like any snack bar with an action, it stays until it is acted on, so
/// there is time to reach Undo (WCAG 2.2.1). Its close icon dismisses it
/// without undoing: swiping it away needs a pointer and Escape does not
/// reach snack bars (WCAG 2.1.1).
void showUndoSnackBar(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
}) {
  final l10n = context.l10n;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        persist: true,
        showCloseIcon: true,
        action: SnackBarAction(label: l10n.commonUndo, onPressed: onUndo),
      ),
    );
}
