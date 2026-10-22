import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
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
    this.offlineSpeech,
    this.dictionaryPacks,
    this.backupRegistry,
    this.syncService,
    this.phrasebookRepository,
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

  /// Offline voice input (Whisper models and transcription) behind
  /// [speechInputService]; null where it cannot run (web, unsupported
  /// CPUs).
  final OfflineSpeech? offlineSpeech;

  /// The offline dictionaries (Wiktionary packs) of the Dictionary tab,
  /// the short-query panel and the Offline languages screen; null in tests
  /// that don't need them (the widgets then work as before, with AI only).
  final DictionaryPacks? dictionaryPacks;

  /// On-device translation engine (also used by [translationRepository]):
  /// Mozilla's Bergamot engine (`lib/platform/offline_engine.dart`), or an
  /// engine that is never available where it cannot run (web).
  final OfflineTranslator offlineTranslator;

  /// Per-provider AI usage counters and budgets.
  final UsageTracker usageTracker;

  /// The kinds of data backups, sync and pairing carry
  /// (`createAppBackupRegistry`); null in tests that don't need it.
  final BackupRegistry? backupRegistry;

  /// End-to-end-encrypted sync with the user's WebDAV folder (it holds the
  /// [secrets] it needs itself); null in tests that don't need it.
  final SyncService? syncService;

  /// The phrasebook (`createPhrasebookRepository`); the app gives it the
  /// history's favourites. Null in tests that don't need it (its entry
  /// points are then hidden).
  final PhrasebookRepository? phrasebookRepository;

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
