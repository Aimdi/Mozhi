import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_transcript.dart';
import 'package:mozhi/conversation/widgets/conversation_turn_bubble.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:share_plus/share_plus.dart';

/// Hands the formatted transcript to the platform share sheet. [origin] is
/// the button's rectangle (needed by iPad / macOS popovers).
typedef ConversationShareCallback = Future<void> Function(
  String text, {
  String? subject,
  Rect? origin,
});

/// Default [ConversationShareCallback] backed by `share_plus`.
Future<void> shareConversationText(
  String text, {
  String? subject,
  Rect? origin,
}) async {
  await SharePlus.instance.share(
    ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
  );
}

/// Entry point for the translate screen's app bar: opens conversation mode.
class ConversationModeButton extends StatelessWidget {
  const ConversationModeButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('conversation_mode_button'),
    tooltip: context.l10n.conversationOpen,
    icon: const Icon(Icons.forum_outlined),
    onPressed: onPressed,
  );
}

/// Toggles reading each new translation aloud.
class ConversationAutoSpeakButton extends StatelessWidget {
  const ConversationAutoSpeakButton({super.key});

  @override
  Widget build(BuildContext context) {
    final autoSpeak = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.autoSpeak,
    );
    return IconButton(
      key: const Key('conversation_auto_speak'),
      tooltip: context.l10n.conversationAutoSpeak,
      isSelected: autoSpeak,
      icon: const Icon(Icons.voice_over_off_outlined),
      selectedIcon: const Icon(Icons.record_voice_over),
      onPressed: () =>
          context.read<ConversationCubit>().setAutoSpeak(enabled: !autoSpeak),
    );
  }
}

/// Switches between the shared standard layout and face-to-face mode.
class ConversationLayoutButton extends StatelessWidget {
  const ConversationLayoutButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final faceToFace = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.faceToFace,
    );
    return IconButton(
      key: const Key('conversation_layout_toggle'),
      tooltip: faceToFace
          ? l10n.conversationFaceToFaceExit
          : l10n.conversationFaceToFaceEnter,
      isSelected: faceToFace,
      icon: const Icon(Icons.people_outline),
      selectedIcon: const Icon(Icons.close_fullscreen),
      onPressed: () =>
          context.read<ConversationCubit>().setFaceToFace(enabled: !faceToFace),
    );
  }
}

enum _MenuAction { copy, share, clear }

/// Overflow menu: copy or share the transcript, clear the conversation.
class ConversationMenuButton extends StatelessWidget {
  const ConversationMenuButton({this.share = shareConversationText, super.key});

  final ConversationShareCallback share;

  String _transcript(BuildContext context, ConversationState state) =>
      ConversationTranscript.format(
        state.turns,
        title: context.l10n.conversationTranscriptTitle(
          state.languageA.name,
          state.languageB.name,
        ),
        formatTime: (time) => formatConversationTime(context, time),
      );

  Future<void> _copy(BuildContext context, ConversationState state) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = context.l10n.commonCopied;
    await Clipboard.setData(ClipboardData(text: _transcript(context, state)));
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(BuildContext context, ConversationState state) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    await share(
      _transcript(context, state),
      subject: context.l10n.conversationTitle,
      origin: origin,
    );
  }

  Future<void> _clear(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<ConversationCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.conversationClearTitle),
        content: Text(l10n.conversationClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('conversation_clear_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonClear),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await cubit.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final empty = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.isEmpty,
    );
    return PopupMenuButton<_MenuAction>(
      key: const Key('conversation_menu'),
      tooltip: l10n.commonMoreOptions,
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        final state = context.read<ConversationCubit>().state;
        unawaited(switch (action) {
          _MenuAction.copy => _copy(context, state),
          _MenuAction.share => _share(context, state),
          _MenuAction.clear => _clear(context),
        });
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('conversation_menu_copy'),
          value: _MenuAction.copy,
          enabled: !empty,
          child: ListTile(
            leading: const Icon(Icons.content_copy_outlined),
            title: Text(l10n.conversationCopyTranscript),
          ),
        ),
        PopupMenuItem(
          key: const Key('conversation_menu_share'),
          value: _MenuAction.share,
          enabled: !empty,
          child: ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(l10n.conversationShareTranscript),
          ),
        ),
        PopupMenuItem(
          key: const Key('conversation_menu_clear'),
          value: _MenuAction.clear,
          enabled: !empty,
          child: ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(l10n.conversationClear),
          ),
        ),
      ],
    );
  }
}
