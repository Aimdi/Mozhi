import 'package:flutter/widgets.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:translation_repository/translation_repository.dart';

/// Receives dictated text: [text] is the whole utterance so far (not just
/// the new words); [isFinal] marks the end of the utterance.
typedef ConversationMicResultCallback = void Function(
  String text, {
  required bool isFinal,
});

/// What a side's microphone button needs in order to dictate into that
/// side's composer.
///
/// Conversation mode does not depend on a particular speech recogniser: the
/// app passes a [ConversationMicBuilder] to `ConversationPage` that builds
/// its voice input button from this request. While dictating, partial
/// results replace the composer's text; a final, non-empty result is sent
/// (translated) right away.
@immutable
class ConversationMicRequest {
  const new({
    required this.side,
    required this.language,
    required this.onResult,
  });

  /// Whose composer the button belongs to.
  final ConversationSide side;

  /// The language this side speaks (recogniser locale hint).
  final Language language;

  /// Call with recognised text (see [ConversationMicResultCallback]).
  final ConversationMicResultCallback onResult;

  /// Stable owner token for a shared speech input service (e.g.
  /// `SpeechInputService.listen(owner: request.owner)`), so only this
  /// side's button reacts to its own session. It is the [side] value, which
  /// is identical across rebuilds.
  Object get owner => side;
}

/// Builds the microphone button for one side of the conversation.
typedef ConversationMicBuilder = Widget Function(
  BuildContext context,
  ConversationMicRequest request,
);
