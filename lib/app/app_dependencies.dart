import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Long-lived services created once by `bootstrap` and handed to the `App`,
/// which provides them to the widget tree and disposes them.
class AppDependencies {
  const new({
    required this.translationRepository,
    required this.settingsRepository,
    required this.historyRepository,
    required this.speechService,
    required this.sharedTextService,
    required this.settings,
    required this.preferences,
    required this.secrets,
    required this.speechInputService,
    required this.offlineTranslator,
    required this.usageTracker,
    this._network,
  });

  final TranslationRepository translationRepository;
  final SettingsRepository settingsRepository;
  final HistoryRepository historyRepository;

  /// Text-to-speech.
  final SpeechService speechService;
  final SharedTextService sharedTextService;

  /// Settings loaded from storage before the first frame.
  final AppSettings settings;

  /// Plain (non-secret) preferences; provided to the widget tree as the
  /// app's [KeyValueStore].
  final KeyValueStore preferences;

  /// Where API keys are kept. Never provided to the widget tree.
  final KeyValueStore secrets;

  /// Speech-to-text (voice input).
  final SpeechInputService speechInputService;

  /// On-device translation engine (also used by [translationRepository]).
  final OfflineTranslator offlineTranslator;

  /// Per-provider AI usage counters and budgets.
  final UsageTracker usageTracker;

  final NetworkSession? _network;

  /// The proxy and HTTP client of this run, shared by every backend client
  /// of [translationRepository] ([NetworkSession.current] when none was
  /// given).
  NetworkSession get network => _network ?? NetworkSession.current;

  /// Whether API keys are only kept in memory for this session because the
  /// platform's secure storage is unavailable.
  bool get secretsInMemory => switch (secrets) {
    final FallbackKeyValueStore store => store.usingFallback,
    _ => false,
  };
}
