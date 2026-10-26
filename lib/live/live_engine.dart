import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// The engine the live features (the live camera and live captions)
/// translate with: [AppSettings.liveEngineId] when [engines] still has it,
/// else the offline engine ([TranslationEngine.offlineId]).
///
/// [engines] are the engines the app offers now (the repository's list);
/// the offline engine is used even when it is not among them, so the
/// caller's translation fails with the usual "download the language"
/// error instead of picking a network engine on its own.
TranslationEngine resolveLiveEngine(
  AppSettings settings,
  List<TranslationEngine> engines,
) {
  final id = settings.liveEngineId;
  if (id != null) {
    for (final engine in engines) {
      if (engine.id == id) return engine;
    }
  }
  for (final engine in engines) {
    if (engine.id == TranslationEngine.offlineId) return engine;
  }
  return TranslationEngine.offline();
}

/// Whether [engine] sends text off the device (any engine but the offline
/// one and on-device AI), so a live feature asks once before it streams
/// text to it.
bool liveEngineLeavesDevice(TranslationEngine engine) => !engine.isOnDevice;
