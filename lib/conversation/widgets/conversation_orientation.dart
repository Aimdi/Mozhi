import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

/// Marks a subtree that is shown upside down (side B's half in
/// face-to-face mode), so dialogs opened from it are rotated as well and
/// read the right way up for the person across the table.
class ConversationOrientation extends InheritedWidget {
  const new({required this.upsideDown, required super.child, super.key});

  final bool upsideDown;

  /// Whether [context] is inside an upside-down half (false when there is
  /// no [ConversationOrientation] above it).
  static bool upsideDownOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ConversationOrientation>()
          ?.upsideDown ??
      false;

  @override
  bool updateShouldNotify(ConversationOrientation oldWidget) =>
      oldWidget.upsideDown != upsideDown;
}

/// [showDialog] that turns the dialog by 180° when opened from an
/// upside-down half.
Future<T?> showConversationDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final upsideDown = ConversationOrientation.upsideDownOf(context);
  return showDialog<T>(
    context: context,
    builder: (dialogContext) {
      final dialog = builder(dialogContext);
      return upsideDown ? RotatedBox(quarterTurns: 2, child: dialog) : dialog;
    },
  );
}

/// Friendly text for a failed turn's error.
String describeConversationError(AppLocalizations l10n, Object? error) =>
    switch (error) {
      ConversationNoEngineException() => l10n.conversationNoEngine,
      _ => describeTranslateError(l10n, error).message,
    };
