import 'dart:async';
import 'dart:typed_data';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:translation_repository/translation_repository.dart';

class MockMozhiApiClient extends Mock implements MozhiApiClient;

class MockLlmClient extends Mock implements LlmClient;

class MockDeeplClient extends Mock implements DeeplClient;

class MockLibreTranslateClient extends Mock implements LibreTranslateClient;

/// An [OfflineTranslator] that records its calls.
class FakeOfflineTranslator implements OfflineTranslator {
  new({
    this.isAvailable = true,
    this.supportedLanguages = const {'en', 'de', 'fr', 'zh', 'he'},
    this.identified,
    this.downloaded,
  });

  @override
  bool isAvailable;

  @override
  Set<String> supportedLanguages;

  /// What [identifyLanguage] returns.
  String? identified;

  /// What [downloadedLanguages] returns (null: [supportedLanguages]).
  Set<String>? downloaded;

  /// Thrown by [translate] when set.
  Exception? error;

  final List<({String text, String source, String target})> calls = [];
  final List<String> identifyCalls = [];

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    calls.add((text: text, source: source, target: target));
    if (error case final error?) throw error;
    return '$text ($source>$target)';
  }

  @override
  Future<String?> identifyLanguage(String text) async {
    identifyCalls.add(text);
    return identified;
  }

  @override
  Future<Set<String>> downloadedLanguages() async =>
      downloaded ?? supportedLanguages;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<void> dispose() async {}
}

/// Registers fallback values for `any()` matchers.
void registerTestFallbacks() {
  registerFallbackValue(const LlmRequest(model: 'fallback', messages: []));
  registerFallbackValue(Uint8List(0));
  registerFallbackValue(DeeplLanguageType.target);
}

/// Ids of the providers the tests configure.
const testProviderIds = [
  'claude',
  'openai',
  'ollama',
  'off',
  'deepl',
  'libre',
  'gemma',
  'cloud-gemma',
];

/// Lets every request of [repository] through, as before privacy modes
/// existed: [PrivacyMode.online] with every test provider consented.
TranslationRepository allowNetwork(TranslationRepository repository) =>
    repository..updatePrivacy(
      mode: PrivacyMode.online,
      consentedProviders: testProviderIds,
    );

const instanceA = MozhiInstance(url: 'https://a.example', label: 'Alpha');
const instanceB = MozhiInstance(url: 'https://b.example');
const instanceC = MozhiInstance(url: 'https://c.example', label: 'Gamma');

const claudeConfig = AiProviderConfig(
  id: 'claude',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
  apiKey: 'sk-ant',
  temperature: 0.2,
  effort: 'low',
);

const openAiConfig = AiProviderConfig(
  id: 'openai',
  name: 'OpenAI',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://api.openai.com/v1',
  model: 'gpt-x',
  apiKey: 'sk-oai',
  temperature: 0.3,
  effort: 'medium',
);

const ollamaConfig = AiProviderConfig(
  id: 'ollama',
  name: 'Local Qwen',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'qwen3',
);

const disabledConfig = AiProviderConfig(
  id: 'off',
  name: 'Disabled',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://api.example.com/v1',
  model: 'm',
  enabled: false,
);

const deeplConfig = AiProviderConfig(
  id: 'deepl',
  name: 'DeepL',
  provider: LlmProvider.openAiCompatible,
  baseUrl: '',
  model: '',
  apiKey: 'key:fx',
  service: MtService.deepl,
);

const libreConfig = AiProviderConfig(
  id: 'libre',
  name: 'Libre',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'http://localhost:5000',
  model: '',
  service: MtService.libreTranslate,
);

const gemmaConfig = AiProviderConfig(
  id: 'gemma',
  name: 'TranslateGemma',
  provider: LlmProvider.ollama,
  baseUrl: 'http://gemma.local:11434',
  model: 'translategemma:4b',
);

const cloudGemmaConfig = AiProviderConfig(
  id: 'cloud-gemma',
  name: 'Hosted Hy-MT',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://mt.example.com/v1',
  model: 'Hunyuan-MT-7B',
);

TranslationEngine mtEngine(AiProviderConfig config) => TranslationEngine(
  id: 'mt:${config.id}',
  kind: EngineKind.mt,
  name: config.name,
  providerId: config.id,
  mtService: config.service,
);

TranslationEngine aiEngine(AiProviderConfig config) => TranslationEngine(
  id: 'ai:${config.id}',
  kind: EngineKind.ai,
  name: config.name,
  subtitle: config.model,
  providerId: config.id,
  promptProfile: config.resolvedPromptProfile,
);

final googleEngine = TranslationEngine.mozhi('google', 'Google');
final deeplEngine = TranslationEngine.mozhi('deepl', 'DeepL');
final yandexEngine = TranslationEngine.mozhi('yandex', 'Yandex');

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German');
const french = Language(code: 'fr', name: 'French');

MozhiApiException serverError([String message = 'boom']) =>
    MozhiApiException(message, statusCode: 502);

MozhiApiException badRequest([String message = 'bad']) =>
    MozhiApiException(message, statusCode: 400);

/// A delta stream that records whether it was cancelled.
class ControlledDeltas {
  late final StreamController<String> controller = StreamController<String>(
    onCancel: () => cancelled = true,
  );
  bool cancelled = false;

  Stream<String> get stream => controller.stream;
}
