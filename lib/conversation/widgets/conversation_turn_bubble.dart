import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_listen_button.dart';
import 'package:mozhi/conversation/widgets/conversation_orientation.dart';
import 'package:mozhi/conversation/widgets/side_colors.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// Formats [time] as the locale's short time of day.
String formatConversationTime(BuildContext context, DateTime time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(time),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// One message of the transcript, styled like a direct message: the
/// reader's own messages (end aligned) in the primary container, the other
/// side's in a neutral raised surface, each next to the speaker's language
/// avatar, with time · engine and the actions below the bubble.
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
    await copyText(text);
    // Android 13+ confirms copies itself.
    if (systemShowsCopyConfirmation) return;
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
    final alignEnd = viewer == null ? turn.side == ConversationSide.b : _mine;
    final colors = alignEnd
        ? ConversationBubbleColors.own(context)
        : ConversationBubbleColors.other(context);
    final palette = AppPalette.of(context);
    final large = theme.textTheme.titleMedium?.copyWith(
      color: colors.onContainer,
      fontWeight: FontWeight.w400,
      fontSize: 16,
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
    final guest = turn.guest;
    final details = [
      // Written by a guest of the conversation shared on the network.
      if (guest != null) l10n.conversationShareGuestLabel(guest),
      formatConversationTime(context, turn.createdAt),
      ?turn.engineName,
    ].join(' · ');
    // Rounded, with a smaller corner toward the speaker.
    final radius = BorderRadiusDirectional.only(
      topStart: const Radius.circular(20),
      topEnd: const Radius.circular(20),
      bottomStart: Radius.circular(alignEnd ? 20 : 4),
      bottomEnd: Radius.circular(alignEnd ? 4 : 20),
    );
    final speaker = turn.source.isAuto ? turn.target : turn.source;
    final avatar = LanguageAvatar(
      code: speaker.isCustom ? speaker.name : speaker.code,
      size: 28,
    );

    // Lined up with the bottom of the bubble, above the 48 dp footer.
    final avatarBesideBubble = Padding(
      padding: const EdgeInsets.only(bottom: 48),
      child: avatar,
    );

    final bubble = Material(
      color: colors.container,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          16,
          10,
          16,
          turn.isFailed ? 4 : 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: texts,
              ),
            ),
            if (turn.error case final ConsentRequiredException consent
                when turn.isFailed)
              // Nothing was sent: the user decides, then it is translated.
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ConsentInlinePrompt(
                  key: Key('conversation_consent_${turn.id}'),
                  consent: consent,
                  onGranted: () => unawaited(
                    context.read<ConversationCubit>().retry(turn.id),
                  ),
                ),
              )
            else if (turn.isFailed)
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
          ],
        ),
      ),
    );

    final footer = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                details,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
            ),
          ),
        ),
        ConversationListenButton(
          buttonKey: Key('conversation_listen_${turn.id}'),
          playing: speaking,
          color: palette.secondaryText,
          onListen: hasTranslation
              ? () =>
                    unawaited(context.read<ConversationCubit>().speak(turn.id))
              : null,
          onListenSlowly: hasTranslation
              ? () => unawaited(
                  context.read<ConversationCubit>().speak(turn.id, slow: true),
                )
              : null,
        ),
        IconButton(
          key: Key('conversation_copy_${turn.id}'),
          tooltip: l10n.conversationCopyTranslation,
          color: palette.secondaryText,
          icon: const Icon(Icons.copy_rounded, size: 20),
          onPressed: hasTranslation
              ? () => unawaited(_copy(context, turn.translation))
              : null,
        ),
        IconButton(
          key: Key('conversation_more_${turn.id}'),
          tooltip: l10n.commonMoreOptions,
          color: palette.secondaryText,
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          onPressed: () => unawaited(_showMore(context)),
        ),
      ],
    );

    final message = l10n.conversationMessageSemantics(
      turn.source.name,
      turn.original,
      turn.target.name,
      status,
    );
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        container: true,
        label: guest == null
            ? message
            : l10n.conversationShareGuestSemantics(
                l10n.conversationShareGuestLabel(guest),
                message,
              ),
        child: Row(
          mainAxisAlignment: alignEnd
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!alignEnd) ...[avatarBesideBubble, const SizedBox(width: 8)],
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.8,
                ),
                child: Column(
                  crossAxisAlignment: alignEnd
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [bubble, footer],
                ),
              ),
            ),
            if (alignEnd) ...[const SizedBox(width: 8), avatarBesideBubble],
          ],
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
