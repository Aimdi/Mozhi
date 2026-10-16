import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';

/// Theme colours that identify a side's controls (language buttons):
/// side A uses the primary palette, side B the tertiary one.
///
/// Message bubbles do not use them: like direct messages, the bubbles a
/// person sent are in `ConversationBubbleColors.own`, the others in
/// `ConversationBubbleColors.other`, and each side keeps its language
/// avatar.
@immutable
class ConversationSideColors {
  const new({
    required this.container,
    required this.onContainer,
    required this.accent,
    required this.onAccent,
  });

  factory of(BuildContext context, ConversationSide side) {
    final scheme = Theme.of(context).colorScheme;
    return switch (side) {
      ConversationSide.a => ConversationSideColors(
        container: scheme.primaryContainer,
        onContainer: scheme.onPrimaryContainer,
        accent: scheme.primary,
        onAccent: scheme.onPrimary,
      ),
      ConversationSide.b => ConversationSideColors(
        container: scheme.tertiaryContainer,
        onContainer: scheme.onTertiaryContainer,
        accent: scheme.tertiary,
        onAccent: scheme.onTertiary,
      ),
    };
  }

  final Color container;
  final Color onContainer;
  final Color accent;
  final Color onAccent;
}

/// Direct-message bubble colours: `own` for the reader's own messages
/// (end aligned), `other` for the rest.
@immutable
class ConversationBubbleColors {
  const new({required this.container, required this.onContainer});

  /// The scheme's primary container (contrast-checked by the app theme).
  factory own(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConversationBubbleColors(
      container: scheme.primaryContainer,
      onContainer: scheme.onPrimaryContainer,
    );
  }

  /// A raised neutral surface.
  factory other(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConversationBubbleColors(
      container: scheme.surfaceContainerHigh,
      onContainer: scheme.onSurface,
    );
  }

  final Color container;
  final Color onContainer;
}
