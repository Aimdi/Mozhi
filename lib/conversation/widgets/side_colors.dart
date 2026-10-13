import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';

/// Theme colours that identify a side everywhere in conversation mode:
/// side A uses the primary palette, side B the tertiary one.
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
