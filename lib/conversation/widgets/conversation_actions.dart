import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_transcript.dart';
import 'package:mozhi/conversation/widgets/conversation_turn_bubble.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
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

/// Toggles reading each new translation aloud.
class ConversationAutoSpeakButton extends StatelessWidget {
  const new({super.key});

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
  const new({super.key});

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

enum _MenuAction { autoSpeak, copy, share, clear, transcribe }

/// Overflow menu: copy or share the transcript, clear the conversation,
/// open Transcribe (a rolling transcript of a talk; with a [GoRouter]
/// above); with [showAutoSpeak] (narrow app bars) also the
/// [ConversationAutoSpeakButton]'s toggle, as a checked item.
class ConversationMenuButton extends StatelessWidget {
  const new({
    this.share = shareConversationText,
    this.showAutoSpeak = false,
    super.key,
  });

  final ConversationShareCallback share;

  /// Offer "Read translations aloud" as the first item.
  final bool showAutoSpeak;

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
    await copyText(_transcript(context, state));
    // Android 13+ confirms copies itself.
    if (systemShowsCopyConfirmation) return;
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
        final cubit = context.read<ConversationCubit>();
        final state = cubit.state;
        switch (action) {
          case _MenuAction.autoSpeak:
            cubit.setAutoSpeak(enabled: !state.autoSpeak);
          case _MenuAction.copy:
            unawaited(_copy(context, state));
          case _MenuAction.share:
            unawaited(_share(context, state));
          case _MenuAction.clear:
            unawaited(_clear(context));
          case _MenuAction.transcribe:
            unawaited(GoRouter.of(context).push<void>(AppRoutes.transcribe));
        }
      },
      itemBuilder: (context) => [
        if (showAutoSpeak) ...[
          CheckedPopupMenuItem(
            key: const Key('conversation_menu_auto_speak'),
            value: _MenuAction.autoSpeak,
            checked: context.read<ConversationCubit>().state.autoSpeak,
            child: Text(l10n.conversationAutoSpeak),
          ),
          const PopupMenuDivider(),
        ],
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
