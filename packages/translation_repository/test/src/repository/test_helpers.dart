import 'dart:async';
import 'dart:typed_data';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

class MockMozhiApiClient extends Mock implements MozhiApiClient;

class MockLlmClient extends Mock implements LlmClient;

/// Registers fallback values for `any()` matchers.
void registerTestFallbacks() {
  registerFallbackValue(const LlmRequest(model: 'fallback', messages: []));
  registerFallbackValue(Uint8List(0));
}

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

TranslationEngine aiEngine(AiProviderConfig config) => TranslationEngine(
  id: 'ai:${config.id}',
  kind: EngineKind.ai,
  name: config.name,
  subtitle: config.model,
  providerId: config.id,
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
