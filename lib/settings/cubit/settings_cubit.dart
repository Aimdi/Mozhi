import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// App-wide settings. Every mutation emits immediately and persists
/// asynchronously (errors are reported via `addError`, never thrown).
///
/// `repository` defaults to a [SettingsRepository] backed by the platform
/// stores. Typical bootstrap:
/// `SettingsCubit(repository: repo, initial: await repo.load())`.
class SettingsCubit extends Cubit<AppSettings> {
  new({SettingsRepository? repository, AppSettings? initial})
    : _repository = repository ?? SettingsRepository(),
      super(initial ?? const AppSettings());

  /// Maximum number of [AppSettings.recentLanguages].
  static const maxRecentLanguages = 8;

  final SettingsRepository _repository;

  /// Reloads from storage.
  Future<void> load() async {
    try {
      final settings = await _repository.load();
      if (!isClosed) emit(settings);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  void update(AppSettings Function(AppSettings current) change) =>
      _apply(change(state));

  // Appearance
  void setThemeMode(ThemeMode mode) => _apply(state.copyWith(themeMode: mode));

  void setDynamicColor({required bool enabled}) =>
      _apply(state.copyWith(dynamicColor: enabled));

  void setPureBlack({required bool enabled}) =>
      _apply(state.copyWith(pureBlack: enabled));

  void setSeedColor(int argb) => _apply(state.copyWith(seedColor: argb));

  // Mozhi instances (ordered by preference)

  /// Appends [instance]; an existing entry with the same url is replaced in
  /// place instead (e.g. to update its label).
  void addInstance(MozhiInstance instance) {
    final instances = [...state.instances];
    final index = instances.indexWhere((i) => i.url == instance.url);
    if (index == -1) {
      instances.add(instance);
    } else {
      instances[index] = instance;
    }
    _apply(state.copyWith(instances: List.unmodifiable(instances)));
  }

  /// Removes the instance with [url] (the list may become empty).
  void removeInstance(String url) => _apply(
    state.copyWith(
      instances: List.unmodifiable(state.instances.where((i) => i.url != url)),
    ),
  );

  /// Reorders with `ReorderableListView.onReorder` semantics: [newIndex] is
  /// the insertion index before removal, so it is decremented when moving
  /// an item down. Out-of-range indices are ignored/clamped.
  void moveInstance(int oldIndex, int newIndex) {
    final instances = [...state.instances];
    if (oldIndex < 0 || oldIndex >= instances.length) return;
    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    target = target.clamp(0, instances.length - 1);
    if (target == oldIndex) return;
    final instance = instances.removeAt(oldIndex);
    instances.insert(target, instance);
    _apply(state.copyWith(instances: List.unmodifiable(instances)));
  }

  /// Moves [url] to the front (becomes preferred).
  void preferInstance(String url) {
    final index = state.instances.indexWhere((i) => i.url == url);
    if (index <= 0) return;
    moveInstance(index, 0);
  }

  void resetInstances() =>
      _apply(state.copyWith(instances: MozhiInstance.publicInstances));

  // AI providers
  /// Inserts or replaces by id.
  void saveProvider(AiProviderConfig provider) {
    final providers = [...state.providers];
    final index = providers.indexWhere((p) => p.id == provider.id);
    if (index == -1) {
      providers.add(provider);
    } else {
      providers[index] = provider;
    }
    _apply(state.copyWith(providers: List.unmodifiable(providers)));
  }

  /// Removes the provider and clears every selection that points at its
  /// engine (`ai:<id>`): [AppSettings.engineId],
  /// [AppSettings.assistEngineId] and [AppSettings.compareEngineIds].
  void removeProvider(String id) {
    final engineId = 'ai:$id';
    _apply(
      state.copyWith(
        providers: List.unmodifiable(state.providers.where((p) => p.id != id)),
        engineId: state.engineId == engineId ? () => null : null,
        assistEngineId: state.assistEngineId == engineId ? () => null : null,
        compareEngineIds: List.unmodifiable(
          state.compareEngineIds.where((e) => e != engineId),
        ),
      ),
    );
  }

  void setProviderEnabled(String id, {required bool enabled}) => _apply(
    state.copyWith(
      providers: List.unmodifiable([
        for (final provider in state.providers)
          if (provider.id == id)
            provider.copyWith(enabled: enabled)
          else
            provider,
      ]),
    ),
  );

  // Translation defaults / selection
  void setEngine(String? engineId) =>
      _apply(state.copyWith(engineId: () => engineId));

  void setAssistEngine(String? engineId) =>
      _apply(state.copyWith(assistEngineId: () => engineId));

  /// Replaces whichever of [source] / [target] is given.
  void setLanguages({Language? source, Language? target}) =>
      _apply(state.copyWith(source: source, target: target));

  /// Pushes [language] to the front of recents (dedupe, max 8; `auto`
  /// never stored).
  void addRecentLanguage(Language language) {
    if (language.isAuto) return;
    final recents = [
      language,
      ...state.recentLanguages.where((l) => l != language),
    ].take(maxRecentLanguages);
    _apply(state.copyWith(recentLanguages: List.unmodifiable(recents)));
  }

  /// Unpins [language] when pinned, otherwise appends it to the pins.
  void togglePinnedLanguage(Language language) {
    final pinned = state.pinnedLanguages.contains(language)
        ? state.pinnedLanguages.where((l) => l != language)
        : [...state.pinnedLanguages, language];
    _apply(state.copyWith(pinnedLanguages: List.unmodifiable(pinned)));
  }

  void setOptions(TranslationOptions options) =>
      _apply(state.copyWith(options: options));

  void setInstantTranslate({required bool enabled}) =>
      _apply(state.copyWith(instantTranslate: enabled));

  void setInstantTranslateAi({required bool enabled}) =>
      _apply(state.copyWith(instantTranslateAi: enabled));

  void setSaveHistory({required bool enabled}) =>
      _apply(state.copyWith(saveHistory: enabled));

  void setShowTransliteration({required bool enabled}) =>
      _apply(state.copyWith(showTransliteration: enabled));

  void setCompareEngines(List<String> engineIds) =>
      _apply(state.copyWith(compareEngineIds: List.unmodifiable(engineIds)));

  void completeOnboarding() => _apply(state.copyWith(onboardingComplete: true));

  /// Emits [next] and persists it in the background. No-op when nothing
  /// changed or the cubit is closed.
  void _apply(AppSettings next) {
    if (isClosed || next == state) return;
    emit(next);
    unawaited(_persist(next));
  }

  Future<void> _persist(AppSettings settings) async {
    try {
      await _repository.save(settings);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }
}
