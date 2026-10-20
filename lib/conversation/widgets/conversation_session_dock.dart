import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/widgets/conversation_session_mic.dart';
import 'package:mozhi/conversation/widgets/conversation_session_status.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The controls of a hands-free conversation, docked above the language
/// pill: the status line and the large microphone, with a keyboard button
/// at its end that shows or hides the text fields ([onToggleComposers];
/// none when null).
///
/// [compact] (little height, e.g. while the keyboard is open) puts a
/// smaller microphone, the status and the keyboard button in one row.
class ConversationSessionDock extends StatelessWidget {
  const new({
    this.composersShown = false,
    this.onToggleComposers,
    this.compact = false,
    super.key,
  });

  /// Whether the text fields are shown (the keyboard button is selected).
  final bool composersShown;

  /// Shows or hides the text fields; null leaves the button out.
  final VoidCallback? onToggleComposers;

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final onToggle = onToggleComposers;
    final keyboard = onToggle == null
        ? null
        : ConversationKeyboardButton(
            shown: composersShown,
            onPressed: onToggle,
          );
    if (compact) {
      return Padding(
        key: const Key('conversation_session_dock'),
        padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 8, 4),
        child: Row(
          children: [
            const ConversationSessionMic(
              size: ConversationSessionMic.compactSize,
            ),
            const SizedBox(width: 8),
            const Expanded(child: ConversationSessionStatus(compact: true)),
            ?keyboard,
          ],
        ),
      );
    }
    return Padding(
      key: const Key('conversation_session_dock'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ConversationSessionStatus(),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Keeps the microphone centred.
              if (keyboard != null) const SizedBox(width: 56),
              const ConversationSessionMic(),
              if (keyboard != null) ...[const SizedBox(width: 8), keyboard],
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows ([shown] false) or hides the text fields of a hands-free
/// conversation.
class ConversationKeyboardButton extends StatelessWidget {
  const new({required this.shown, required this.onPressed, super.key});

  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return IconButton(
      key: const Key('conversation_keyboard_toggle'),
      tooltip: shown
          ? l10n.conversationHideKeyboard
          : l10n.conversationShowKeyboard,
      isSelected: shown,
      icon: const Icon(Icons.keyboard_outlined),
      selectedIcon: const Icon(Icons.keyboard_hide_outlined),
      onPressed: onPressed,
    );
  }
}

/// A small "Beta" badge: the hands-free conversation is new.
class ConversationBetaBadge extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      key: const Key('conversation_beta_badge'),
      decoration: ShapeDecoration(
        color: scheme.tertiaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text(
          context.l10n.conversationBeta,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onTertiaryContainer,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
