import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// A change of the settings: the settings with it applied to [current].
typedef _SettingsChange = AppSettings Function(AppSettings current);

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

  /// The failure [error] (thrown by [SettingsRepository.update]) stands
  /// for.
  static SettingsSaveFailure of(Object error) =>
      error is SecretStorageException ? secret : settings;
}

/// App-wide settings. Every mutation emits immediately and persists
/// asynchronously (errors are reported via `addError`, never thrown, and
/// on [saveFailures]): only what it changed, applied to the stored
/// settings, so that what another window of the app changed meanwhile is
/// kept. The app reads them again ([load]) when its window comes back to
/// the front and, on the web, when another tab changed them
/// ([isStorageKey]).
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

  /// Whether a change of the browser's storage under [key] (null: all of
  /// it was cleared) may have changed the settings: their JSON or their
  /// secrets (API keys, headers, instance credentials; see
  /// [SettingsRepository]). The web app then reads them again ([load]):
  /// another tab changed them.
  static bool isStorageKey(String? key) =>
      key == null ||
      [
        SettingsRepository.settingsKey,
        SettingsRepository.apiKeyKey(''),
        SettingsRepository.headersKey(''),
        SettingsRepository.instanceCredentialsKey,
      ].any(key.contains);

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
  /// the settings read may not hold it yet), e.g. after another window of
  /// the app changed them. The changes not written yet stay applied.
  Future<void> load() async {
    try {
      final changes = _changes;
      final settings = await _repository.load();
      if (isClosed) return;
      if (_changes != changes) return await load();
      emit(_withUnsaved(settings));
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Applies [change] to the settings in use, and to the stored ones (see
  /// [_apply]).
  void update(AppSettings Function(AppSettings current) change) =>
      _apply(change);

  // Appearance
  void setThemeMode(ThemeMode mode) =>
      _apply((s) => s.copyWith(themeMode: mode));

  void setDynamicColor({required bool enabled}) =>
      _apply((s) => s.copyWith(dynamicColor: enabled));

  void setPureBlack({required bool enabled}) =>
      _apply((s) => s.copyWith(pureBlack: enabled));

  void setSeedColor(int argb) => _apply((s) => s.copyWith(seedColor: argb));

  /// Sets the app's look ([AppSettings.style]).
  void setStyle(AppStyle style) => _apply((s) => s.copyWith(style: style));

  /// Sets the terminal look's accent ([AppSettings.terminalAccent]); a
  /// colour that is not one of [kTerminalAccents] is ignored.
  void setTerminalAccent(int argb) {
    if (!kTerminalAccents.contains(argb)) return;
    _apply((s) => s.copyWith(terminalAccent: argb));
  }

  // General

  /// Sets the language of the app's texts ([AppSettings.appLocale]) as a
  /// language tag; null or blank follows the device.
  void setAppLocale(String? tag) {
    final value = tag?.trim();
    _apply(
      (s) => s.copyWith(
        appLocale: () => (value == null || value.isEmpty) ? null : value,
      ),
    );
  }

  void setHapticFeedback({required bool enabled}) =>
      _apply((s) => s.copyWith(hapticFeedback: enabled));

  /// Sets the order of the tabs; missing tabs are added after the given
  /// ones and duplicates dropped ([AppSettings.normalizeTabOrder]).
  void setTabOrder(List<AppTab> order) =>
      _apply((s) => s.copyWith(tabOrder: AppSettings.normalizeTabOrder(order)));

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
      _apply((s) => s.copyWith(rememberQuality: enabled));

  void setMultilineInput({required bool enabled}) =>
      _apply((s) => s.copyWith(multilineInput: enabled));

  // Mozhi instances (ordered by preference)

  /// Appends [instance]; an existing entry with the same url is replaced in
  /// place instead (e.g. to update its label).
  void addInstance(MozhiInstance instance) => _apply((s) {
    final instances = [...s.instances];
    final index = instances.indexWhere((i) => i.url == instance.url);
    if (index == -1) {
      instances.add(instance);
    } else {
      instances[index] = instance;
    }
    return s.copyWith(instances: List.unmodifiable(instances));
  });

  /// Removes the instance with [url] (the list may become empty).
  void removeInstance(String url) => _apply(
    (s) => s.copyWith(
      instances: List.unmodifiable(s.instances.where((i) => i.url != url)),
    ),
  );

  /// Reorders with `ReorderableListView.onReorder` semantics: [newIndex] is
  /// the insertion index before removal, so it is decremented when moving
  /// an item down. Out-of-range indices are ignored/clamped.
  void moveInstance(int oldIndex, int newIndex) {
    final shown = state.instances;
    if (oldIndex < 0 || oldIndex >= shown.length) return;
    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    target = target.clamp(0, shown.length - 1);
    if (target == oldIndex) return;
    // The instance the user moved, to where they moved it, in the stored
    // list (another window may have changed it).
    final url = shown[oldIndex].url;
    _apply((s) {
      final instances = [...s.instances];
      final index = instances.indexWhere((i) => i.url == url);
      if (index == -1) return s;
      final instance = instances.removeAt(index);
      instances.insert(target.clamp(0, instances.length), instance);
      return s.copyWith(instances: List.unmodifiable(instances));
    });
  }

  /// Moves [url] to the front (becomes preferred).
  void preferInstance(String url) {
    final index = state.instances.indexWhere((i) => i.url == url);
    if (index <= 0) return;
    moveInstance(index, 0);
  }

  void resetInstances() =>
      _apply((s) => s.copyWith(instances: MozhiInstance.publicInstances));

  // AI providers
  /// Inserts or replaces by id.
  void saveProvider(AiProviderConfig provider) => _apply((s) {
    final providers = [...s.providers];
    final index = providers.indexWhere((p) => p.id == provider.id);
    if (index == -1) {
      providers.add(provider);
    } else {
      providers[index] = provider;
    }
    return s.copyWith(providers: List.unmodifiable(providers));
  });

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
      (s) => s.copyWith(
        providers: List.unmodifiable(s.providers.where((p) => p.id != id)),
        engineId: cleared(s.engineId),
        assistEngineId: cleared(s.assistEngineId),
        fastEngineId: cleared(s.fastEngineId),
        bestEngineId: cleared(s.bestEngineId),
        liveEngineId: cleared(s.liveEngineId),
        compareEngineIds: List.unmodifiable(
          s.compareEngineIds.where((e) => !engineIds.contains(e)),
        ),
      ),
    );
  }

  void setProviderEnabled(String id, {required bool enabled}) => _apply(
    (s) => s.copyWith(
      providers: List.unmodifiable([
        for (final provider in s.providers)
          if (provider.id == id)
            provider.copyWith(enabled: enabled)
          else
            provider,
      ]),
    ),
  );

  // Translation defaults / selection
  void setEngine(String? engineId) =>
      _apply((s) => s.copyWith(engineId: () => engineId));

  void setAssistEngine(String? engineId) =>
      _apply((s) => s.copyWith(assistEngineId: () => engineId));

  /// Replaces whichever of [source] / [target] is given.
  void setLanguages({Language? source, Language? target}) =>
      _apply((s) => s.copyWith(source: source, target: target));

  /// Pushes [language] to the front of recents (dedupe, max 8; `auto`
  /// never stored).
  void addRecentLanguage(Language language) {
    if (language.isAuto) return;
    _apply(
      (s) => s.copyWith(
        recentLanguages: List.unmodifiable(
          [
            language,
            ...s.recentLanguages.where((l) => l != language),
          ].take(maxRecentLanguages),
        ),
      ),
    );
  }

  /// Pushes the pair [source] → [target] to the front of
  /// [AppSettings.recentPairs] (dedupe, max [maxRecentPairs]). An `auto`
  /// source is a valid pair; an `auto` target, or a target equal to the
  /// source, is ignored.
  void recordPair(Language source, Language target) {
    if (target.isAuto || source == target) return;
    final pair = LanguagePair(source: source, target: target);
    _apply(
      (s) => s.copyWith(
        recentPairs: List.unmodifiable(
          [pair, ...s.recentPairs.where((p) => p != pair)].take(maxRecentPairs),
        ),
      ),
    );
  }

  /// Forgets every recent language pair.
  void clearRecentPairs() => _apply((s) => s.copyWith(recentPairs: const []));

  /// Unpins [language] when pinned, otherwise appends it to the pins.
  void togglePinnedLanguage(Language language) {
    // Toggled as the user sees it; applied to the stored pins.
    final pin = !state.pinnedLanguages.contains(language);
    _apply((s) {
      final pinned = s.pinnedLanguages.where((l) => l != language);
      return s.copyWith(
        pinnedLanguages: List.unmodifiable([...pinned, if (pin) language]),
      );
    });
  }

  /// Saves the additional target languages of the translate screen ("Also
  /// translate into…"): `auto` and duplicates are dropped and at most
  /// [AppSettings.maxExtraTargets] are kept, in the given order
  /// ([AppSettings.normalizeExtraTargets]).
  void setExtraTargets(List<Language> targets) => _apply(
    (s) => s.copyWith(extraTargets: AppSettings.normalizeExtraTargets(targets)),
  );

  void setOptions(TranslationOptions options) =>
      _apply((s) => s.copyWith(options: options));

  void setInstantTranslate({required bool enabled}) =>
      _apply((s) => s.copyWith(instantTranslate: enabled));

  void setInstantTranslateAi({required bool enabled}) =>
      _apply((s) => s.copyWith(instantTranslateAi: enabled));

  void setSaveHistory({required bool enabled}) =>
      _apply((s) => s.copyWith(saveHistory: enabled));

  // Privacy

  void setPrivacyMode(PrivacyMode mode) =>
      _apply((s) => s.copyWith(privacyMode: mode));

  /// Allows the language pair [pairKey] (`TranslationRepository.pairKey`)
  /// to go to the network in [PrivacyMode.offlineFirst].
  void approveNetworkPair(String pairKey) {
    if (pairKey.isEmpty || state.networkPairs.contains(pairKey)) return;
    _apply(
      (s) => s.networkPairs.contains(pairKey)
          ? s
          : s.copyWith(
              networkPairs: List.unmodifiable([...s.networkPairs, pairKey]),
            ),
    );
  }

  /// Forgets every pair approved with [approveNetworkPair].
  void clearNetworkPairs() => _apply((s) => s.copyWith(networkPairs: const []));

  /// Records the user's consent to send text to the cloud provider [id].
  void consentToProvider(String id) {
    if (id.isEmpty || state.consentedProviders.contains(id)) return;
    _apply(
      (s) => s.consentedProviders.contains(id)
          ? s
          : s.copyWith(
              consentedProviders: List.unmodifiable([
                ...s.consentedProviders,
                id,
              ]),
            ),
    );
  }

  /// Withdraws the consent given with [consentToProvider].
  void revokeProviderConsent(String id) => _apply(
    (s) => s.copyWith(
      consentedProviders: List.unmodifiable(
        s.consentedProviders.where((p) => p != id),
      ),
    ),
  );

  void setIncognito({required bool enabled}) =>
      _apply((s) => s.copyWith(incognito: enabled));

  void setSecureScreen({required bool enabled}) =>
      _apply((s) => s.copyWith(secureScreen: enabled));

  /// The app lock's timeout (`AppSettings.appLock`). Turning it on is up
  /// to the caller to confirm first (one successful unlock, see
  /// `AppLockController.confirm`), so nobody locks themselves out.
  void setAppLock(AppLockTimeout timeout) =>
      _apply((s) => s.copyWith(appLock: timeout));

  /// The engine of the live features (`AppSettings.liveEngineId`; null =
  /// the offline engine). A network engine is confirmed by the caller
  /// first (`showLiveEnginePicker`).
  void setLiveEngine(String? id) =>
      _apply((s) => s.copyWith(liveEngineId: () => id));

  /// "Tap a word to look it up" (`AppSettings.tapToLookUp`).
  void setTapToLookUp({required bool enabled}) =>
      _apply((s) => s.copyWith(tapToLookUp: enabled));

  /// "Highlight the word being read" (`AppSettings.highlightSpokenWord`).
  void setHighlightSpokenWord({required bool enabled}) =>
      _apply((s) => s.copyWith(highlightSpokenWord: enabled));

  /// "Keep the web app for offline use" (`AppSettings.offlineAppShell`).
  void setOfflineAppShell({required bool enabled}) =>
      _apply((s) => s.copyWith(offlineAppShell: enabled));

  /// "Hide personal data from online engines"
  /// (`AppSettings.maskPersonalData`).
  void setMaskPersonalData({required bool enabled}) =>
      _apply((s) => s.copyWith(maskPersonalData: enabled));

  /// "If Google fails, use DuckDuckGo"
  /// (`AppSettings.fallbackToDuckDuckGo`), as the user's own choice
  /// (`AppSettings.fallbackToDuckDuckGoChosen`), which a later start keeps.
  void setFallbackToDuckDuckGo({required bool enabled}) => _apply(
    (s) => s.copyWith(
      fallbackToDuckDuckGo: enabled,
      fallbackToDuckDuckGoChosen: true,
    ),
  );

  /// Where on-device models are downloaded from
  /// (`AppSettings.modelSource`).
  void setModelSource(ModelSource source) =>
      _apply((s) => s.copyWith(modelSource: source));

  /// Sets the HTTP proxy (`host:port`); null or blank = no proxy.
  void setHttpProxy(String? proxy) {
    final value = proxy?.trim();
    _apply(
      (s) => s.copyWith(
        httpProxy: () => (value == null || value.isEmpty) ? null : value,
      ),
    );
  }

  void setShowTransliteration({required bool enabled}) =>
      _apply((s) => s.copyWith(showTransliteration: enabled));

  /// How long non-favourite history entries are kept. Applying it to the
  /// stored history is up to whoever listens (see
  /// `HistoryRetentionListener`).
  void setHistoryRetention(HistoryRetention retention) =>
      _apply((s) => s.copyWith(historyRetention: retention));

  // Quality modes (Kagi-style Fast / Best)

  /// Sets the engines of [QualityMode.fast] and [QualityMode.best]. Both are
  /// replaced: null means "not chosen". Use `state.fastEngineId` /
  /// `state.bestEngineId` to keep the other one.
  void setQualityEngines({String? fast, String? best}) => _apply(
    (s) => s.copyWith(fastEngineId: () => fast, bestEngineId: () => best),
  );

  /// Remembers the quality mode of the translate screen.
  void setQualityMode(QualityMode mode) =>
      _apply((s) => s.copyWith(qualityMode: mode));

  void setCompareEngines(List<String> engineIds) =>
      _apply((s) => s.copyWith(compareEngineIds: List.unmodifiable(engineIds)));

  void completeOnboarding() =>
      _apply((s) => s.copyWith(onboardingComplete: true));

  /// Emits [change] applied to the settings in use and persists it in the
  /// background. No-op when nothing changed or the cubit is closed.
  ///
  /// Persisting applies [change] to the *stored* settings, read again in
  /// the same step ([SettingsRepository.update]), instead of writing the
  /// settings in use: another window of the app (a second browser tab, the
  /// quick translate window on Android, each with a copy of its own) may
  /// have changed others since, and they are kept. A change that could not
  /// be written is applied again with the next one.
  void _apply(_SettingsChange change) {
    if (isClosed) return;
    final next = change(state);
    if (next == state) return;
    _changes++;
    _unsaved.add(change);
    emit(next);
    unawaited(_persist());
  }

  /// The changes not written yet (in order): being written, or whose
  /// write failed.
  final _unsaved = <_SettingsChange>[];

  /// [settings] with the changes not written yet ([_unsaved]).
  AppSettings _withUnsaved(AppSettings settings) =>
      _unsaved.fold(settings, (settings, change) => change(settings));

  Future<void> _persist() async {
    var written = const <_SettingsChange>[];
    try {
      await _repository.update((stored) {
        written = [..._unsaved];
        return _withUnsaved(stored);
      });
      // Applied again by a later write that started meanwhile: changes
      // set values, so applying one twice changes nothing.
      _unsaved.removeWhere(written.contains);
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
