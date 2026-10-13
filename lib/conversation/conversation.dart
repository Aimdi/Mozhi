/// Conversation mode ("face to face"): two people speaking different
/// languages take turns; each message is translated for the other side.
///
/// Entry point: `ConversationPage` (needs `TranslationRepository`,
/// `SpeechService`, `TranslateCubit` and `SettingsCubit` above it).
library;

export 'cubit/conversation_cubit.dart';
export 'models/models.dart';
export 'view/conversation_page.dart';
export 'widgets/conversation_actions.dart'
    show
        ConversationModeButton,
        ConversationShareCallback,
        shareConversationText;
export 'widgets/conversation_voice_mic.dart';
