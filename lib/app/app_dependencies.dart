import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Long-lived services created once by `bootstrap` and handed to the `App`,
/// which provides them to the widget tree.
class AppDependencies {
  const AppDependencies({
    required this.translationRepository,
    required this.settingsRepository,
    required this.historyRepository,
    required this.speechService,
    required this.sharedTextService,
    required this.settings,
  });

  final TranslationRepository translationRepository;
  final SettingsRepository settingsRepository;
  final HistoryRepository historyRepository;
  final SpeechService speechService;
  final SharedTextService sharedTextService;

  /// Settings loaded from storage before the first frame.
  final AppSettings settings;
}
