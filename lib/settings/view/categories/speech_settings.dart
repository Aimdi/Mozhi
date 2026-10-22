import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/speech_settings_section.dart';
import 'package:mozhi/settings/view/widgets/voice_input_settings_section.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/voice/speech_input_service.dart';

/// Anchors ([SettingsAnchor.id]) of the Read aloud & voice settings.
abstract final class SpeechAnchors {
  static const readAloud = 'read_aloud';
  static const voiceInput = 'voice_input';
}

/// The Read aloud & voice settings: read aloud ([SpeechSettingsSection],
/// with a [SpeechService]) and voice input ([VoiceInputSettingsSection],
/// where speech recognition runs).
class SpeechCategorySettings extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  /// Whether read aloud has its settings (a [SpeechService] is provided).
  static bool readAloudAvailable(BuildContext context) =>
      _maybeRead<SpeechService>(context) != null;

  /// Whether voice input has its settings (speech recognition runs here).
  static bool voiceInputAvailable(BuildContext context) =>
      _maybeRead<SpeechInputService>(context)?.isPlatformSupported ?? false;

  /// Whether the category has anything to show.
  static bool available(BuildContext context) =>
      readAloudAvailable(context) || voiceInputAvailable(context);

  static T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (readAloudAvailable(context))
        SettingsAnchor(
          id: SpeechAnchors.readAloud,
          child: SpeechSettingsSection(
            languages: [
              settings.target,
              settings.source,
              ...settings.recentLanguages,
            ],
          ),
        ),
      SettingsAnchor(
        id: SpeechAnchors.voiceInput,
        child: VoiceInputSettingsSection(privacyMode: settings.privacyMode),
      ),
    ],
  );
}
