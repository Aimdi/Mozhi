import 'package:equatable/equatable.dart';
import 'package:material_ui/material_ui.dart';
import 'package:translation_repository/translation_repository.dart';

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
  });

  factory fromJson() {
    throw UnimplementedError('TODO(app-data)');
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
  }) {
    throw UnimplementedError('TODO(app-data)');
  }

  /// Excludes API keys. Unknown/missing fields fall back to defaults so old
  /// JSON keeps loading.
  Map<String, dynamic> toJson() {
    throw UnimplementedError('TODO(app-data)');
  }

  @override
  List<Object?> get props => [
    themeMode,
    dynamicColor,
    pureBlack,
    seedColor,
    instances,
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
  ];
}
