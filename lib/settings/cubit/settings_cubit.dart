import 'package:bloc/bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// App-wide settings. Every mutation emits immediately and persists
/// asynchronously (errors are reported via `addError`, never thrown).
class SettingsCubit extends Cubit<AppSettings> {
  new({AppSettings? initial})
    : super(initial ?? const AppSettings());

  /// Reloads from storage.
  Future<void> load() => throw UnimplementedError('TODO(app-data)');

  void update(AppSettings Function(AppSettings current) change) =>
      throw UnimplementedError('TODO(app-data)');

  // Appearance
  void setThemeMode(ThemeMode mode) => throw UnimplementedError();
  void setDynamicColor({required bool enabled}) => throw UnimplementedError();
  void setPureBlack({required bool enabled}) => throw UnimplementedError();
  void setSeedColor(int argb) => throw UnimplementedError();

  // Mozhi instances (ordered by preference)
  void addInstance(MozhiInstance instance) => throw UnimplementedError();
  void removeInstance(String url) => throw UnimplementedError();
  void moveInstance(int oldIndex, int newIndex) => throw UnimplementedError();

  /// Moves [url] to the front (becomes preferred).
  void preferInstance(String url) => throw UnimplementedError();
  void resetInstances() => throw UnimplementedError();

  // AI providers
  /// Inserts or replaces by id.
  void saveProvider(AiProviderConfig provider) => throw UnimplementedError();
  void removeProvider(String id) => throw UnimplementedError();
  void setProviderEnabled(String id, {required bool enabled}) =>
      throw UnimplementedError();

  // Translation defaults / selection
  void setEngine(String? engineId) => throw UnimplementedError();
  void setAssistEngine(String? engineId) => throw UnimplementedError();
  void setLanguages({Language? source, Language? target}) =>
      throw UnimplementedError();

  /// Pushes [language] to the front of recents (dedupe, max 8; `auto`
  /// never stored).
  void addRecentLanguage(Language language) => throw UnimplementedError();
  void togglePinnedLanguage(Language language) => throw UnimplementedError();
  void setOptions(TranslationOptions options) => throw UnimplementedError();
  void setInstantTranslate({required bool enabled}) =>
      throw UnimplementedError();
  void setInstantTranslateAi({required bool enabled}) =>
      throw UnimplementedError();
  void setSaveHistory({required bool enabled}) => throw UnimplementedError();
  void setShowTransliteration({required bool enabled}) =>
      throw UnimplementedError();
  void setCompareEngines(List<String> engineIds) => throw UnimplementedError();
  void completeOnboarding() => throw UnimplementedError();
}
