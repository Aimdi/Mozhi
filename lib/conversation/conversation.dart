/// Conversation mode ("face to face"): two people speaking different
/// languages take turns; each message is translated for the other side,
/// typed, dictated or hands-free (the large microphone listens, translates,
/// reads aloud and listens for the other side, see `ConversationSession`).
///
/// Entry point: `ConversationPage` (needs `TranslationRepository`,
/// `SpeechService`, `TranslateCubit` and `SettingsCubit` above it, and
/// `SpeechInputService` for voice input).
library;

export 'cubit/conversation_cubit.dart';
export 'models/models.dart';
export 'recognizer/conversation_recognizer.dart';
export 'recognizer/speech_input_conversation_recognizer.dart';
export 'view/conversation_page.dart';
export 'widgets/conversation_actions.dart'
    show ConversationShareCallback, shareConversationText;
export 'widgets/conversation_voice_mic.dart';
