import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart';

/// What the hands-free conversation of [state] is doing, for people: how
/// to start it while idle; whose turn it is and in which language the
/// microphone listens ("Listening in Spanish…"); translating; reading
/// aloud; or why it paused or failed and how to go on.
String conversationSessionStatus(
  AppLocalizations l10n,
  ConversationState state,
) => switch (state.session) {
  ConversationSessionIdle() => l10n.conversationHeroHint,
  ConversationSessionListening(stage: ConversationListenStage.transcribing) =>
    l10n.conversationSessionTranscribing,
  ConversationSessionListening(:final heard) when heard.trim().isNotEmpty =>
    heard.trim(),
  ConversationSessionListening(:final side, detectsLanguage: true) =>
    l10n.conversationSessionListeningEither(
      state.languageOf(side).name,
      state.languageOf(side.other).name,
    ),
  ConversationSessionListening(:final side) =>
    l10n.conversationSessionListening(state.languageOf(side).name),
  ConversationSessionTranslating() => l10n.conversationTranslating,
  ConversationSessionSpeaking(:final turnId, :final next) =>
    l10n.conversationSessionSpeaking(
      (turnId == null ? null : state.turnById(turnId))?.target.name ??
          state.languageOf(next.other).name,
    ),
  ConversationSessionPaused(:final reason) => switch (reason) {
    ConversationPauseReason.silence => l10n.conversationSessionPausedSilence,
    ConversationPauseReason.interrupted => l10n.conversationSessionPaused,
    ConversationPauseReason.consent => l10n.conversationSessionPausedConsent,
    ConversationPauseReason.speechConsent =>
      l10n.conversationSessionPausedSpeechConsent,
    ConversationPauseReason.translationFailed =>
      l10n.conversationSessionPausedFailed,
  },
  ConversationSessionFailed(
    :final failure,
    :final onDevice,
    :final offlineSupported,
  ) =>
    l10n.conversationSessionFailed(
      voiceInputErrorMessage(
        l10n,
        failure,
        onDevice: onDevice,
        offlineModelDownloadable: voiceInputFailureNeedsOfflineModel(
          failure,
          offlineSupported: offlineSupported,
        ),
      ),
    ),
};

/// The status line above the hands-free conversation's microphone
/// ([conversationSessionStatus]), led by the avatar of the language whose
/// turn it is while a conversation is active. Centred, or start aligned
/// when [compact] (next to a small microphone).
///
/// It is not a live region: announcing every change would talk over the
/// translations read aloud (and the microphone would hear it). The
/// microphone's semantics carry the status instead; `ConversationView`
/// announces why a conversation paused.
class ConversationSessionStatus extends StatelessWidget {
  const new({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<ConversationCubit>().state;
    final session = state.session;
    final side = session.side;
    final language = side == null ? null : state.languageOf(side);
    final text = conversationSessionStatus(l10n, state);
    final warning = session is ConversationSessionFailed;
    final style = theme.textTheme.bodyLarge?.copyWith(
      color: warning
          ? theme.colorScheme.error
          : session.isRunning
          ? theme.colorScheme.onSurface
          : AppPalette.of(context).secondaryText,
    );
    // While active the microphone's semantics carry the status.
    return ExcludeSemantics(
      excluding: session.isActive,
      child: Row(
        key: const Key('conversation_session_status'),
        mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: compact
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          if (language != null && session.isActive) ...[
            LanguageAvatar(code: language.code, size: 24),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              text,
              key: const Key('conversation_session_status_text'),
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              textAlign: compact ? TextAlign.start : TextAlign.center,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}
