import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_orientation.dart';
import 'package:mozhi/conversation/widgets/side_colors.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Formats [time] as the locale's short time of day.
String formatConversationTime(BuildContext context, DateTime time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(time),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// One message of the transcript.
///
/// With a [viewer] (face-to-face halves) the viewer's own messages sit at
/// the end and show what they said in large type; the other side's
/// messages sit at the start and show the translation in large type.
/// Without a viewer (shared standard layout) side A sits at the start,
/// side B at the end, and the translation is the large text.
class ConversationTurnBubble extends StatelessWidget {
  const new({
    required this.turn,
    this.viewer,
    this.speaking = false,
    super.key,
  });

  final ConversationTurn turn;
  final ConversationSide? viewer;

  /// Whether this turn's translation is being read aloud.
  final bool speaking;

  bool get _mine => viewer != null && turn.side == viewer;

  Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = context.l10n.commonCopied;
    await Clipboard.setData(ClipboardData(text: text));
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showMore(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<ConversationCubit>();
    final action = await showConversationDialog<_TurnAction>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        children: [
          _DialogOption(
            icon: Icons.content_copy_outlined,
            label: l10n.conversationCopyOriginal,
            value: _TurnAction.copyOriginal,
          ),
          if (turn.translation.trim().isNotEmpty)
            _DialogOption(
              icon: Icons.translate,
              label: l10n.conversationCopyTranslation,
              value: _TurnAction.copyTranslation,
            ),
          _DialogOption(
            icon: Icons.delete_outline,
            label: l10n.conversationDeleteMessage,
            value: _TurnAction.delete,
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _TurnAction.copyOriginal:
        await _copy(context, turn.original);
      case _TurnAction.copyTranslation:
        await _copy(context, turn.translation);
      case _TurnAction.delete:
        await cubit.removeTurn(turn.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = ConversationSideColors.of(context, turn.side);
    final alignEnd = viewer == null ? turn.side == ConversationSide.b : _mine;
    final large = theme.textTheme.titleMedium?.copyWith(
      color: colors.onContainer,
      height: 1.35,
    );
    final small = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onContainer.withValues(alpha: 0.78),
    );

    final original = Text(turn.original, style: _mine ? large : small);
    final translation = _Translation(
      turn: turn,
      style: _mine ? small : large,
      color: colors.onContainer,
    );
    // The other side's messages lead with the translation the viewer reads.
    final texts = viewer != null && !_mine
        ? [translation, const SizedBox(height: 6), original]
        : [original, const SizedBox(height: 6), translation];

    final hasTranslation = turn.translation.trim().isNotEmpty;
    final status = turn.isFailed
        ? describeConversationError(l10n, turn.error)
        : turn.translation.trim().isEmpty
        ? l10n.conversationTranslating
        : turn.translation;
    final details = [
      formatConversationTime(context, turn.createdAt),
      ?turn.engineName,
    ].join(' · ');
    final radius = BorderRadiusDirectional.only(
      topStart: const Radius.circular(20),
      topEnd: const Radius.circular(20),
      bottomStart: Radius.circular(alignEnd ? 20 : 6),
      bottomEnd: Radius.circular(alignEnd ? 6 : 20),
    );

    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: alignEnd
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.86),
          child: Semantics(
            container: true,
            label: l10n.conversationMessageSemantics(
              turn.source.name,
              turn.original,
              turn.target.name,
              status,
            ),
            child: Material(
              color: colors.container,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 4, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 12),
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: texts,
                        ),
                      ),
                    ),
                    if (turn.isFailed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: TextButton.icon(
                          key: Key('conversation_retry_${turn.id}'),
                          onPressed: () => unawaited(
                            context.read<ConversationCubit>().retry(turn.id),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onContainer,
                          ),
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.commonRetry),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: ExcludeSemantics(
                            child: Text(
                              details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.onContainer.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: Key('conversation_listen_${turn.id}'),
                          tooltip: speaking
                              ? l10n.commonStop
                              : l10n.commonListen,
                          isSelected: speaking,
                          color: colors.onContainer,
                          icon: const Icon(Icons.volume_up_outlined),
                          selectedIcon: const Icon(Icons.stop_circle_outlined),
                          onPressed: hasTranslation
                              ? () => unawaited(
                                  context.read<ConversationCubit>().speak(
                                    turn.id,
                                  ),
                                )
                              : null,
                        ),
                        IconButton(
                          key: Key('conversation_copy_${turn.id}'),
                          tooltip: l10n.conversationCopyTranslation,
                          color: colors.onContainer,
                          icon: const Icon(Icons.content_copy_outlined),
                          onPressed: hasTranslation
                              ? () =>
                                    unawaited(_copy(context, turn.translation))
                              : null,
                        ),
                        IconButton(
                          key: Key('conversation_more_${turn.id}'),
                          tooltip: l10n.commonMoreOptions,
                          color: colors.onContainer,
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => unawaited(_showMore(context)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _TurnAction { copyOriginal, copyTranslation, delete }

class _DialogOption extends StatelessWidget {
  const new({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final _TurnAction value;

  @override
  Widget build(BuildContext context) => SimpleDialogOption(
    onPressed: () => Navigator.of(context).pop(value),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
    child: Row(
      children: [
        Icon(icon),
        const SizedBox(width: 16),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

/// The translation part of a bubble: streaming text, progress or error.
class _Translation extends StatelessWidget {
  const new({required this.turn, required this.style, required this.color});

  final ConversationTurn turn;
  final TextStyle? style;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (turn.isFailed) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 20, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              describeConversationError(l10n, turn.error),
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      );
    }
    final text = turn.translation.trim();
    if (text.isEmpty && turn.isTranslating) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          const SizedBox(width: 10),
          Flexible(child: Text(l10n.conversationTranslating, style: style)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: style),
        if (turn.isTranslating)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              minHeight: 2,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
      ],
    );
  }
}
