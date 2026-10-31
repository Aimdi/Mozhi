import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// Why saving the settings failed (see [SettingsCubit.saveFailures]).
enum SettingsSaveFailure {
  /// The settings could not be written (storage error, or stored settings
  /// that could not be read are not overwritten:
  /// [SettingsUnavailableException]). The changes last until the app
  /// closes.
  settings,

  /// Secure storage refused an API key, custom headers or an instance
  /// password ([SecretStorageException]). It is kept in memory until the
  /// app closes, never in plain storage.
  secret;

  /// The failure [error] (thrown by [SettingsRepository.save]) stands for.
  static SettingsSaveFailure of(Object error) =>
      error is SecretStorageException ? secret : settings;
}

/// App-wide settings. Every mutation emits immediately and persists
/// asynchronously (errors are reported via `addError`, never thrown, and
/// on [saveFailures]).
///
/// `repository` defaults to a [SettingsRepository] backed by the platform
/// stores. Typical bootstrap:
/// `SettingsCubit(repository: repo, initial: await repo.load())`.
class SettingsCubit extends Cubit<AppSettings> {
  new({SettingsRepository? repository, AppSettings? initial})
    : _repository = repository ?? SettingsRepository(),
      super(initial ?? const AppSettings()) {
    ModelSource.current = state.modelSource;
  }

  /// Maximum number of [AppSettings.recentLanguages].
  static const maxRecentLanguages = 8;

  /// Maximum number of [AppSettings.recentPairs].
  static const maxRecentPairs = 8;

  final SettingsRepository _repository;

  final _saveFailures = StreamController<SettingsSaveFailure>.broadcast();

  /// Every failed save, as it happens (e.g. the Keystore refusing an API
  /// key): the state keeps the change, which lasts until the app closes.
  /// Shown to the user by `SettingsSaveFailureListener`.
  // Events, not state: the state stays the settings in use.
  // ignore: prefer_void_public_cubit_methods
  Stream<SettingsSaveFailure> get saveFailures => _saveFailures.stream;

  /// How many changes were made (a load that a change overtook reads
  /// again, so the change is shown).
  int _changes = 0;

  /// Reloads from storage (again when a change was made while reading:
  /// the settings read may not hold it yet).
  Future<void> load() async {
    try {
      final changes = _changes;
      final settings = await _repository.load();
      if (isClosed) return;
      if (_changes != changes) return await load();
      emit(settings);
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

  /// Sets the app's look ([AppSettings.style]).
  void setStyle(AppStyle style) => _apply(state.copyWith(style: style));

  /// Sets the terminal look's accent ([AppSettings.terminalAccent]); a
  /// colour that is not one of [kTerminalAccents] is ignored.
  void setTerminalAccent(int argb) {
    if (!kTerminalAccents.contains(argb)) return;
    _apply(state.copyWith(terminalAccent: argb));
  }

  // General

  /// Sets the language of the app's texts ([AppSettings.appLocale]) as a
  /// language tag; null or blank follows the device.
  void setAppLocale(String? tag) {
    final value = tag?.trim();
    _apply(
      state.copyWith(
        appLocale: () => (value == null || value.isEmpty) ? null : value,
      ),
    );
  }

  void setHapticFeedback({required bool enabled}) =>
      _apply(state.copyWith(hapticFeedback: enabled));

  /// Sets the order of the tabs; missing tabs are added after the given
  /// ones and duplicates dropped ([AppSettings.normalizeTabOrder]).
  void setTabOrder(List<AppTab> order) =>
      _apply(state.copyWith(tabOrder: AppSettings.normalizeTabOrder(order)));

  /// Moves the tab at [oldIndex] of [AppSettings.tabOrder] so that it ends
  /// up at [newIndex] (`ReorderableListView.onReorderItem` semantics).
  /// Out-of-range indices are ignored/clamped.
  void moveTab(int oldIndex, int newIndex) {
    final order = [...state.tabOrder];
    if (oldIndex < 0 || oldIndex >= order.length) return;
    final target = newIndex.clamp(0, order.length - 1);
    if (target == oldIndex) return;
    order.insert(target, order.removeAt(oldIndex));
    setTabOrder(order);
  }

  /// Puts the tabs back in their default order.
  void resetTabOrder() => setTabOrder(AppTab.values);

  void setRememberQuality({required bool enabled}) =>
      _apply(state.copyWith(rememberQuality: enabled));

  void setMultilineInput({required bool enabled}) =>
      _apply(state.copyWith(multilineInput: enabled));

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
  /// engine (`ai:<id>` or `mt:<id>`): [AppSettings.engineId],
  /// [AppSettings.assistEngineId], [AppSettings.fastEngineId],
  /// [AppSettings.bestEngineId], [AppSettings.liveEngineId] and
  /// [AppSettings.compareEngineIds].
  void removeProvider(String id) {
    final engineIds = {'ai:$id', 'mt:$id'};
    String? Function()? cleared(String? current) =>
        engineIds.contains(current) ? () => null : null;
    _apply(
      state.copyWith(
        providers: List.unmodifiable(state.providers.where((p) => p.id != id)),
        engineId: cleared(state.engineId),
        assistEngineId: cleared(state.assistEngineId),
        fastEngineId: cleared(state.fastEngineId),
        bestEngineId: cleared(state.bestEngineId),
        liveEngineId: cleared(state.liveEngineId),
        compareEngineIds: List.unmodifiable(
          state.compareEngineIds.where((e) => !engineIds.contains(e)),
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

  /// Pushes the pair [source] → [target] to the front of
  /// [AppSettings.recentPairs] (dedupe, max [maxRecentPairs]). An `auto`
  /// source is a valid pair; an `auto` target, or a target equal to the
  /// source, is ignored.
  void recordPair(Language source, Language target) {
    if (target.isAuto || source == target) return;
    final pair = LanguagePair(source: source, target: target);
    final pairs = [
      pair,
      ...state.recentPairs.where((p) => p != pair),
    ].take(maxRecentPairs);
    _apply(state.copyWith(recentPairs: List.unmodifiable(pairs)));
  }

  /// Forgets every recent language pair.
  void clearRecentPairs() => _apply(state.copyWith(recentPairs: const []));

  /// Unpins [language] when pinned, otherwise appends it to the pins.
  void togglePinnedLanguage(Language language) {
    final pinned = state.pinnedLanguages.contains(language)
        ? state.pinnedLanguages.where((l) => l != language)
        : [...state.pinnedLanguages, language];
    _apply(state.copyWith(pinnedLanguages: List.unmodifiable(pinned)));
  }

  /// Saves the additional target languages of the translate screen ("Also
  /// translate into…"): `auto` and duplicates are dropped and at most
  /// [AppSettings.maxExtraTargets] are kept, in the given order
  /// ([AppSettings.normalizeExtraTargets]).
  void setExtraTargets(List<Language> targets) => _apply(
    state.copyWith(extraTargets: AppSettings.normalizeExtraTargets(targets)),
  );

  void setOptions(TranslationOptions options) =>
      _apply(state.copyWith(options: options));

  void setInstantTranslate({required bool enabled}) =>
      _apply(state.copyWith(instantTranslate: enabled));

  void setInstantTranslateAi({required bool enabled}) =>
      _apply(state.copyWith(instantTranslateAi: enabled));

  void setSaveHistory({required bool enabled}) =>
      _apply(state.copyWith(saveHistory: enabled));

  // Privacy

  void setPrivacyMode(PrivacyMode mode) =>
      _apply(state.copyWith(privacyMode: mode));

  /// Allows the language pair [pairKey] (`TranslationRepository.pairKey`)
  /// to go to the network in [PrivacyMode.offlineFirst].
  void approveNetworkPair(String pairKey) {
    if (pairKey.isEmpty || state.networkPairs.contains(pairKey)) return;
    _apply(
      state.copyWith(
        networkPairs: List.unmodifiable([...state.networkPairs, pairKey]),
      ),
    );
  }

  /// Forgets every pair approved with [approveNetworkPair].
  void clearNetworkPairs() => _apply(state.copyWith(networkPairs: const []));

  /// Records the user's consent to send text to the cloud provider [id].
  void consentToProvider(String id) {
    if (id.isEmpty || state.consentedProviders.contains(id)) return;
    _apply(
      state.copyWith(
        consentedProviders: List.unmodifiable([
          ...state.consentedProviders,
          id,
        ]),
      ),
    );
  }

  /// Withdraws the consent given with [consentToProvider].
  void revokeProviderConsent(String id) => _apply(
    state.copyWith(
      consentedProviders: List.unmodifiable(
        state.consentedProviders.where((p) => p != id),
      ),
    ),
  );

  void setIncognito({required bool enabled}) =>
      _apply(state.copyWith(incognito: enabled));

  void setSecureScreen({required bool enabled}) =>
      _apply(state.copyWith(secureScreen: enabled));

  /// The app lock's timeout (`AppSettings.appLock`). Turning it on is up
  /// to the caller to confirm first (one successful unlock, see
  /// `AppLockController.confirm`), so nobody locks themselves out.
  void setAppLock(AppLockTimeout timeout) =>
      _apply(state.copyWith(appLock: timeout));

  /// The engine of the live features (`AppSettings.liveEngineId`; null =
  /// the offline engine). A network engine is confirmed by the caller
  /// first (`showLiveEnginePicker`).
  void setLiveEngine(String? id) =>
      _apply(state.copyWith(liveEngineId: () => id));

  /// "Tap a word to look it up" (`AppSettings.tapToLookUp`).
  void setTapToLookUp({required bool enabled}) =>
      _apply(state.copyWith(tapToLookUp: enabled));

  /// "Highlight the word being read" (`AppSettings.highlightSpokenWord`).
  void setHighlightSpokenWord({required bool enabled}) =>
      _apply(state.copyWith(highlightSpokenWord: enabled));

  /// "Keep the web app for offline use" (`AppSettings.offlineAppShell`).
  void setOfflineAppShell({required bool enabled}) =>
      _apply(state.copyWith(offlineAppShell: enabled));

  /// "Hide personal data from online engines"
  /// (`AppSettings.maskPersonalData`).
  void setMaskPersonalData({required bool enabled}) =>
      _apply(state.copyWith(maskPersonalData: enabled));

  /// "If Google fails, use DuckDuckGo"
  /// (`AppSettings.fallbackToDuckDuckGo`).
  void setFallbackToDuckDuckGo({required bool enabled}) =>
      _apply(state.copyWith(fallbackToDuckDuckGo: enabled));

  /// Where on-device models are downloaded from
  /// (`AppSettings.modelSource`).
  void setModelSource(ModelSource source) =>
      _apply(state.copyWith(modelSource: source));

  /// Sets the HTTP proxy (`host:port`); null or blank = no proxy.
  void setHttpProxy(String? proxy) {
    final value = proxy?.trim();
    _apply(
      state.copyWith(
        httpProxy: () => (value == null || value.isEmpty) ? null : value,
      ),
    );
  }

  void setShowTransliteration({required bool enabled}) =>
      _apply(state.copyWith(showTransliteration: enabled));

  /// How long non-favourite history entries are kept. Applying it to the
  /// stored history is up to whoever listens (see
  /// `HistoryRetentionListener`).
  void setHistoryRetention(HistoryRetention retention) =>
      _apply(state.copyWith(historyRetention: retention));

  // Quality modes (Kagi-style Fast / Best)

  /// Sets the engines of [QualityMode.fast] and [QualityMode.best]. Both are
  /// replaced: null means "not chosen". Use `state.fastEngineId` /
  /// `state.bestEngineId` to keep the other one.
  void setQualityEngines({String? fast, String? best}) => _apply(
    state.copyWith(fastEngineId: () => fast, bestEngineId: () => best),
  );

  /// Remembers the quality mode of the translate screen.
  void setQualityMode(QualityMode mode) =>
      _apply(state.copyWith(qualityMode: mode));

  void setCompareEngines(List<String> engineIds) =>
      _apply(state.copyWith(compareEngineIds: List.unmodifiable(engineIds)));

  void completeOnboarding() => _apply(state.copyWith(onboardingComplete: true));

  /// Emits [next] and persists it in the background. No-op when nothing
  /// changed or the cubit is closed.
  void _apply(AppSettings next) {
    if (isClosed || next == state) return;
    _changes++;
    emit(next);
    unawaited(_persist(next));
  }

  Future<void> _persist(AppSettings settings) async {
    try {
      await _repository.save(settings);
    } on Object catch (error, stackTrace) {
      if (!_saveFailures.isClosed) {
        _saveFailures.add(SettingsSaveFailure.of(error));
      }
      addError(error, stackTrace);
    }
  }

  /// Keeps [ModelSource.current] (read by the model downloads) equal to
  /// the settings in use.
  @override
  void onChange(Change<AppSettings> change) {
    super.onChange(change);
    ModelSource.current = change.nextState.modelSource;
  }

  @override
  Future<void> close() {
    unawaited(_saveFailures.close());
    return super.close();
  }
}
