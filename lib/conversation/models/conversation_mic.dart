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
///
/// A [prominent] request is the large microphone of an empty conversation
/// (it dictates for [side] too, next to that side's composer button).
@immutable
class ConversationMicRequest {
  const new({
    required this.side,
    required this.language,
    required this.onResult,
    this.prominent = false,
  });

  /// Whose composer the button belongs to.
  final ConversationSide side;

  /// The language this side speaks (recogniser locale hint).
  final Language language;

  /// Call with recognised text (see [ConversationMicResultCallback]).
  final ConversationMicResultCallback onResult;

  /// Build a large, filled button (the empty conversation's main control)
  /// instead of the composer's icon button.
  final bool prominent;

  /// Stable owner token for a shared speech input service (e.g.
  /// `SpeechInputService.listen(owner: request.owner)`), so only this
  /// button reacts to its own session. It is the [side] value (another,
  /// equally stable token for a [prominent] request), which is identical
  /// across rebuilds.
  Object get owner => prominent ? _ProminentOwner.values[side.index] : side;
}

/// Owner tokens of the [ConversationMicRequest.prominent] buttons, one per
/// side.
enum _ProminentOwner { a, b }

/// Builds the microphone button for one side of the conversation.
typedef ConversationMicBuilder = Widget Function(
  BuildContext context,
  ConversationMicRequest request,
);
