import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_turn_bubble.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The transcript, newest message at the bottom (kept in view as messages
/// arrive). Shows a short explanation while empty.
///
/// [viewer] selects the face-to-face perspective (see
/// [ConversationTurnBubble]); null is the shared standard layout.
class ConversationTranscriptList extends StatelessWidget {
  const ConversationTranscriptList({this.viewer, super.key});

  final ConversationSide? viewer;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ConversationCubit, ConversationState>(
      buildWhen: (previous, current) =>
          previous.turns != current.turns ||
          previous.speakingTurnId != current.speakingTurnId,
      builder: (context, state) {
        if (state.turns.isEmpty) return const _EmptyTranscript();
        final turns = state.turns;
        return ListView.separated(
          key: Key('conversation_transcript_${viewer?.name ?? 'shared'}'),
          reverse: true,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: turns.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final turn = turns[turns.length - 1 - index];
            return ConversationTurnBubble(
              key: ValueKey(turn.id),
              turn: turn,
              viewer: viewer,
              speaking: state.speakingTurnId == turn.id,
            );
          },
        );
      },
    );
  }
}

class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.conversationEmptyTitle,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.conversationEmptyBody,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
