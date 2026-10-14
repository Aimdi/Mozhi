import 'package:equatable/equatable.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/language_pair.dart';
import 'package:translation_repository/translation_repository.dart';

export 'language_pair.dart';

/// How long non-favourite history entries are kept before they are
/// deleted automatically. Favourites are always kept.
enum HistoryRetention {
  forever(null),
  day(Duration(days: 1)),
  week(Duration(days: 7)),
  month(Duration(days: 30));

  new(this.maxAge);

  /// Maximum age of a non-favourite history entry; null keeps entries
  /// forever.
  final Duration? maxAge;
}

/// Which engine translates: the normal selection ([off]), the engine
/// picked as "Fast" ([AppSettings.fastEngineId]) or the one picked as
/// "Best" ([AppSettings.bestEngineId]), like Kagi's Standard / Best modes.
enum QualityMode {
  /// Quality modes are not used: [AppSettings.engineId] translates.
  off,

  /// The quick (cheap) engine, e.g. a Mozhi engine.
  fast,

  /// The strongest engine, e.g. the best AI model.
  best,
}

/// Everything the user can configure. Persisted as JSON by
/// `SettingsRepository` (API keys are stored separately, see there).
class AppSettings extends Equatable {
  const new({
    this.themeMode = ThemeMode.system,
    this.dynamicColor = true,
    this.pureBlack = false,
    this.seedColor = 0xFF3F51B5,
    this.instances = MozhiInstance.publicInstances,
    this.providers = const [],
    this.engineId,
    this.assistEngineId,
    this.source = Language.auto,
    this.target = const Language(code: 'en', name: 'English'),
    this.options = const TranslationOptions(),
    this.instantTranslate = true,
    this.instantTranslateAi = false,
    this.saveHistory = true,
    this.showTransliteration = true,
    this.recentLanguages = const [],
    this.pinnedLanguages = const [],
    this.compareEngineIds = const [],
    this.onboardingComplete = false,
    this.historyRetention = HistoryRetention.forever,
    this.fastEngineId,
    this.bestEngineId,
    this.qualityMode = QualityMode.off,
    this.recentPairs = const [],
    this.extraTargets = const [],
  });

  /// Tolerant counterpart of [toJson]: missing or invalid fields fall back to
  /// their defaults and invalid list elements are skipped, so JSON written
  /// by older (or newer) versions keeps loading. Never throws.
  factory fromJson(Map<String, dynamic> json) {
    const defaults = AppSettings();
    return AppSettings(
      themeMode:
          ThemeMode.values.asNameMap()[json['themeMode']] ?? defaults.themeMode,
      dynamicColor: _bool(json['dynamicColor']) ?? defaults.dynamicColor,
      pureBlack: _bool(json['pureBlack']) ?? defaults.pureBlack,
      seedColor: _int(json['seedColor']) ?? defaults.seedColor,
      instances:
          _list(json['instances'], MozhiInstance.fromJson) ??
          defaults.instances,
      providers:
          _list(json['providers'], AiProviderConfig.fromJson) ??
          defaults.providers,
      engineId: _string(json['engineId']),
      assistEngineId: _string(json['assistEngineId']),
      source: _object(json['source'], Language.fromJson) ?? defaults.source,
      target: _object(json['target'], Language.fromJson) ?? defaults.target,
      options:
          _object(json['options'], TranslationOptions.fromJson) ??
          defaults.options,
      instantTranslate:
          _bool(json['instantTranslate']) ?? defaults.instantTranslate,
      instantTranslateAi:
          _bool(json['instantTranslateAi']) ?? defaults.instantTranslateAi,
      saveHistory: _bool(json['saveHistory']) ?? defaults.saveHistory,
      showTransliteration:
          _bool(json['showTransliteration']) ?? defaults.showTransliteration,
      recentLanguages:
          _list(json['recentLanguages'], Language.fromJson) ??
          defaults.recentLanguages,
      pinnedLanguages:
          _list(json['pinnedLanguages'], Language.fromJson) ??
          defaults.pinnedLanguages,
      compareEngineIds: switch (json['compareEngineIds']) {
        final List<dynamic> ids => List.unmodifiable(ids.whereType<String>()),
        _ => defaults.compareEngineIds,
      },
      onboardingComplete:
          _bool(json['onboardingComplete']) ?? defaults.onboardingComplete,
      historyRetention:
          HistoryRetention.values.asNameMap()[json['historyRetention']] ??
          defaults.historyRetention,
      fastEngineId: _string(json['fastEngineId']),
      bestEngineId: _string(json['bestEngineId']),
      qualityMode:
          QualityMode.values.asNameMap()[json['qualityMode']] ??
          defaults.qualityMode,
      recentPairs:
          _list(json['recentPairs'], LanguagePair.fromJson) ??
          defaults.recentPairs,
      extraTargets: normalizeExtraTargets(
        _list(json['extraTargets'], Language.fromJson) ?? defaults.extraTargets,
      ),
    );
  }

  /// Version of the JSON layout written by [toJson].
  static const schemaVersion = 1;

  /// Most [extraTargets].
  static const maxExtraTargets = 4;

  /// [languages] as valid [extraTargets]: without `auto`, languages with an
  /// empty code and duplicates (the first one is kept), at most
  /// [maxExtraTargets], in the given order.
  static List<Language> normalizeExtraTargets(Iterable<Language> languages) {
    final targets = <Language>[];
    for (final language in languages) {
      if (targets.length == maxExtraTargets) break;
      if (language.isAuto ||
          language.code.trim().isEmpty ||
          targets.contains(language)) {
        continue;
      }
      targets.add(language);
    }
    return List.unmodifiable(targets);
  }

  final ThemeMode themeMode;

  /// Use the platform (Material You) palette when available.
  final bool dynamicColor;

  /// AMOLED black backgrounds in dark mode.
  final bool pureBlack;

  /// ARGB seed when [dynamicColor] is off/unavailable.
  final int seedColor;

  /// Ordered by preference; the repository fails over in this order.
  final List<MozhiInstance> instances;

  /// API keys are included in memory but never serialised by [toJson].
  final List<AiProviderConfig> providers;

  /// Selected engine (`mozhi:<engine>` / `ai:<id>`), null = first available.
  final String? engineId;

  /// AI engine used for insights/alternatives/explain/dictionary while the
  /// main engine is a Mozhi engine. Null = first enabled AI provider.
  final String? assistEngineId;
  final Language source;
  final Language target;

  /// Persisted default translation options (AI engines).
  final TranslationOptions options;

  /// Translate while typing for Mozhi engines (debounced ~600 ms).
  final bool instantTranslate;

  /// Translate while typing for AI engines (debounced ~1200 ms; costs
  /// tokens, off by default).
  final bool instantTranslateAi;
  final bool saveHistory;
  final bool showTransliteration;

  /// Most recent first, max 8, includes custom languages.
  final List<Language> recentLanguages;
  final List<Language> pinnedLanguages;

  /// Engines included in compare mode; empty = all available.
  final List<String> compareEngineIds;
  final bool onboardingComplete;

  /// How long non-favourite history entries are kept.
  final HistoryRetention historyRetention;

  /// Engine id used in [QualityMode.fast]; null = not chosen yet.
  final String? fastEngineId;

  /// Engine id used in [QualityMode.best]; null = not chosen yet.
  final String? bestEngineId;

  /// The remembered quality mode of the translate screen.
  final QualityMode qualityMode;

  /// Recently used language pairs, most recent first, without duplicates
  /// (at most `SettingsCubit.maxRecentPairs`).
  final List<LanguagePair> recentPairs;

  /// The additional target languages of the translate screen ("Also
  /// translate into…"), as the user picked them: at most [maxExtraTargets],
  /// never `auto`, without duplicates (see [normalizeExtraTargets]). Kept
  /// when the engine in use does not offer some of them (they are used
  /// again with an engine that does).
  final List<Language> extraTargets;

  /// Returns a copy with the given fields replaced. The nullable
  /// [engineId] / [assistEngineId] / [fastEngineId] / [bestEngineId] take
  /// closures so they can be reset to null: `copyWith(engineId: () => null)`.
  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? dynamicColor,
    bool? pureBlack,
    int? seedColor,
    List<MozhiInstance>? instances,
    List<AiProviderConfig>? providers,
    String? Function()? engineId,
    String? Function()? assistEngineId,
    Language? source,
    Language? target,
    TranslationOptions? options,
    bool? instantTranslate,
    bool? instantTranslateAi,
    bool? saveHistory,
    bool? showTransliteration,
    List<Language>? recentLanguages,
    List<Language>? pinnedLanguages,
    List<String>? compareEngineIds,
    bool? onboardingComplete,
    HistoryRetention? historyRetention,
    String? Function()? fastEngineId,
    String? Function()? bestEngineId,
    QualityMode? qualityMode,
    List<LanguagePair>? recentPairs,
    List<Language>? extraTargets,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      pureBlack: pureBlack ?? this.pureBlack,
      seedColor: seedColor ?? this.seedColor,
      instances: instances ?? this.instances,
      providers: providers ?? this.providers,
      engineId: engineId != null ? engineId() : this.engineId,
      assistEngineId: assistEngineId != null
          ? assistEngineId()
          : this.assistEngineId,
      source: source ?? this.source,
      target: target ?? this.target,
      options: options ?? this.options,
      instantTranslate: instantTranslate ?? this.instantTranslate,
      instantTranslateAi: instantTranslateAi ?? this.instantTranslateAi,
      saveHistory: saveHistory ?? this.saveHistory,
      showTransliteration: showTransliteration ?? this.showTransliteration,
      recentLanguages: recentLanguages ?? this.recentLanguages,
      pinnedLanguages: pinnedLanguages ?? this.pinnedLanguages,
      compareEngineIds: compareEngineIds ?? this.compareEngineIds,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      historyRetention: historyRetention ?? this.historyRetention,
      fastEngineId: fastEngineId != null ? fastEngineId() : this.fastEngineId,
      bestEngineId: bestEngineId != null ? bestEngineId() : this.bestEngineId,
      qualityMode: qualityMode ?? this.qualityMode,
      recentPairs: recentPairs ?? this.recentPairs,
      extraTargets: extraTargets ?? this.extraTargets,
    );
  }

  /// Excludes API keys (and the one-off [TranslationOptions.instructions]).
  /// Unknown/missing fields fall back to defaults so old JSON keeps loading.
  Map<String, dynamic> toJson() {
    return {
      'version': schemaVersion,
      'themeMode': themeMode.name,
      'dynamicColor': dynamicColor,
      'pureBlack': pureBlack,
      'seedColor': seedColor,
      'instances': [for (final instance in instances) instance.toJson()],
      'providers': [
        for (final provider in providers)
          {...provider.toJson()}..remove('apiKey'),
      ],
      'engineId': engineId,
      'assistEngineId': assistEngineId,
      'source': source.toJson(),
      'target': target.toJson(),
      'options': {...options.toJson()}..remove('instructions'),
      'instantTranslate': instantTranslate,
      'instantTranslateAi': instantTranslateAi,
      'saveHistory': saveHistory,
      'showTransliteration': showTransliteration,
      'recentLanguages': [
        for (final language in recentLanguages) language.toJson(),
      ],
      'pinnedLanguages': [
        for (final language in pinnedLanguages) language.toJson(),
      ],
      'compareEngineIds': compareEngineIds,
      'onboardingComplete': onboardingComplete,
      'historyRetention': historyRetention.name,
      'fastEngineId': fastEngineId,
      'bestEngineId': bestEngineId,
      'qualityMode': qualityMode.name,
      'recentPairs': [for (final pair in recentPairs) pair.toJson()],
      'extraTargets': [for (final language in extraTargets) language.toJson()],
    };
  }

  @override
  List<Object?> get props => [
    themeMode,
    dynamicColor,
    pureBlack,
    seedColor,
    // MozhiInstance equality only looks at the url; labels matter here.
    [for (final i in instances) (i.url, i.label, i.isCustom)],
    providers,
    engineId,
    assistEngineId,
    source,
    target,
    options,
    instantTranslate,
    instantTranslateAi,
    saveHistory,
    showTransliteration,
    recentLanguages,
    pinnedLanguages,
    compareEngineIds,
    onboardingComplete,
    historyRetention,
    fastEngineId,
    bestEngineId,
    qualityMode,
    recentPairs,
    extraTargets,
  ];
}

bool? _bool(Object? value) => value is bool ? value : null;

int? _int(Object? value) => value is num ? value.toInt() : null;

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Parses a nested JSON object, or returns null when it is missing/invalid.
T? _object<T>(Object? value, T Function(Map<String, dynamic> json) parse) {
  if (value is! Map) return null;
  try {
    return parse(Map<String, dynamic>.from(value));
  } on Object {
    return null;
  }
}

/// Parses a JSON list element by element, skipping invalid elements. Returns
/// null when [value] is not a list at all.
List<T>? _list<T>(Object? value, T Function(Map<String, dynamic> json) parse) {
  if (value is! List) return null;
  return List.unmodifiable([
    for (final element in value) ?_object(element, parse),
  ]);
}
