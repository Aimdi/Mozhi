import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/voice/widgets/voice_input_button.dart';

/// [ConversationMicBuilder] backed by the app's [VoiceInputButton]: each
/// side dictates in its own language. Requires the app-wide
/// `SpeechInputService` (`RepositoryProvider<SpeechInputService>`) above the
/// page; the button hides itself where speech recognition is unavailable.
Widget conversationVoiceMicBuilder(
  BuildContext context,
  ConversationMicRequest request,
) => VoiceInputButton(
  key: ValueKey('conversation_mic_${request.side.name}'),
  languageCode: request.language.code,
  onResult: request.onResult,
);
