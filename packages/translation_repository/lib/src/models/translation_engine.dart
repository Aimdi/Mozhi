import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/ai_provider_config.dart';
import 'package:translation_repository/src/models/prompt_profile.dart';

/// What kind of backend a [TranslationEngine] uses.
enum EngineKind {
  /// An engine of the active Mozhi instance (`mozhi:<engine>`).
  mozhi,

  /// A configured AI (LLM) provider (`ai:<providerId>`).
  ai,

  /// The injected on-device `OfflineTranslator`
  /// ([TranslationEngine.offlineId]).
  offline,

  /// A machine translation service configured with its own key or server
  /// (DeepL API, LibreTranslate): `mt:<providerId>`, see
  /// [TranslationEngine.mtService].
  mt,
}

/// Something that can translate: a Mozhi engine on the active instance, a
/// configured AI provider, a machine translation service (DeepL /
/// LibreTranslate) or the on-device offline translator.
///
/// Ids are stable across launches: `mozhi:<engine>` (e.g. `mozhi:deepl`),
/// `ai:<providerId>`, `mt:<providerId>` or [offlineId].
@immutable
class TranslationEngine {
  const new({
    required this.id,
    required this.kind,
    required this.name,
    this.subtitle,
    this.mozhiEngine,
    this.providerId,
    this.isLocal = false,
    this.promptProfile,
    this.mtService,
  });

  factory mozhi(String engine, String name) => TranslationEngine(
    id: 'mozhi:$engine',
    kind: EngineKind.mozhi,
    name: name,
    mozhiEngine: engine,
  );

  /// The on-device engine (`offline:mlkit`, "Offline (on-device)").
  factory offline() => const TranslationEngine(
    id: offlineId,
    kind: EngineKind.offline,
    name: 'Offline (on-device)',
    isLocal: true,
  );

  /// Id of the on-device engine.
  static const offlineId = 'offline:mlkit';

  final String id;
  final EngineKind kind;
  final String name;

  /// E.g. the model name for AI engines, or "via mozhi.aryak.me".
  final String? subtitle;
  final String? mozhiEngine;

  /// The [AiProviderConfig.id] of AI and machine translation engines.
  final String? providerId;

  /// Runs on-device / on LAN (privacy badge).
  final bool isLocal;

  /// AI engines: the provider's prompt profile resolved against its model
  /// (never [PromptProfile.auto] for engines from `getEngines`). Null for
  /// other kinds.
  final PromptProfile? promptProfile;

  /// Machine translation engines ([EngineKind.mt]): the service. Null for
  /// other kinds.
  final MtService? mtService;

  bool get isAi => kind == EngineKind.ai;
  bool get isMozhi => kind == EngineKind.mozhi;
  bool get isOffline => kind == EngineKind.offline;
  bool get isMt => kind == EngineKind.mt;

  /// An AI engine whose model is translation-specialised (TranslateGemma,
  /// Hy-MT): plain translation only, no options, custom targets or extras,
  /// and it needs an explicit (or detectable) source language.
  bool get usesMtProfile => isAi && (promptProfile?.isTranslationOnly ?? false);

  /// AI engines with the general prompt profile accept free-form custom
  /// target "languages".
  bool get supportsCustomLanguages => isAi && !usesMtProfile;

  /// AI engines with the general prompt profile honour every
  /// `TranslationOptions` field (style, formality, reading level, genders,
  /// context, glossary, instructions).
  bool get supportsOptions => isAi && !usesMtProfile;

  /// The JSON / chat extras (alternatives, insights, suggestions, explain,
  /// dictionary, proofreading, AI language detection) need an AI engine with
  /// the general prompt profile.
  bool get supportsExtras => isAi && !usesMtProfile;

  /// `TranslationOptions.formality` and `context` are honoured: AI engines
  /// with the general profile, and DeepL (formality is sent as
  /// `prefer_more` / `prefer_less`, the context as DeepL's `context`).
  bool get supportsFormality => supportsOptions || mtService == MtService.deepl;

  /// See [supportsFormality].
  bool get supportsContext => supportsFormality;

  /// Mozhi TTS exists for `google` and `reverso`; AI engines fall back to
  /// whatever TTS the app has (Mozhi google TTS or device TTS).
  bool get supportsTts =>
      isAi || mozhiEngine == 'google' || mozhiEngine == 'reverso';

  @override
  bool operator ==(Object other) =>
      other is TranslationEngine && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'TranslationEngine($id)';
}
