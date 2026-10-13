import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  AiProviderConfig config({
    String baseUrl = 'https://api.openai.com/v1',
    String? apiKey,
    LlmProvider provider = LlmProvider.openAiCompatible,
    Map<String, String> headers = const {},
  }) => AiProviderConfig(
    id: 'p1',
    name: 'Provider',
    provider: provider,
    baseUrl: baseUrl,
    model: 'gpt-5-mini',
    apiKey: apiKey,
    headers: headers,
  );

  group(AiProviderConfig, () {
    const full = AiProviderConfig(
      id: 'abc',
      name: 'Claude',
      provider: LlmProvider.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      model: 'claude-opus-5-5',
      apiKey: 'sk-secret',
      presetId: 'anthropic',
      effort: 'low',
      temperature: 0.3,
      headers: {'X-Test': '1'},
      enabled: false,
      supportsVision: true,
    );

    group('json', () {
      test('never contains the API key', () {
        final json = full.toJson();
        expect(json.containsKey('apiKey'), isFalse);
        expect(json.values, isNot(contains('sk-secret')));
      });

      test('round-trips everything but the key', () {
        final restored = AiProviderConfig.fromJson(full.toJson());
        expect(restored.apiKey, isNull);
        expect(restored, equals(full.copyWith(clearApiKey: true)));
        expect(restored.headers, {'X-Test': '1'});
        expect(restored.presetId, 'anthropic');
        expect(restored.temperature, 0.3);
        expect(restored.enabled, isFalse);
        expect(restored.supportsVision, isTrue);
      });

      test('serialises the provider by name and omits nulls', () {
        final json = config().toJson();
        expect(json['provider'], 'openAiCompatible');
        expect(json.containsKey('effort'), isFalse);
        expect(json.containsKey('temperature'), isFalse);
        expect(json.containsKey('presetId'), isFalse);
        expect(json.containsKey('headers'), isFalse);
        expect(json['enabled'], isTrue);
      });

      test('ignores an apiKey in the input', () {
        final restored = AiProviderConfig.fromJson(const {
          'id': 'x',
          'apiKey': 'leaked',
        });
        expect(restored.apiKey, isNull);
      });

      test('is tolerant of missing and invalid fields', () {
        final restored = AiProviderConfig.fromJson(const {
          'id': 'x',
          'provider': 'something-new',
          'temperature': 1,
          'headers': {'ok': 'yes', 'bad': 2},
          'enabled': 'yes',
          'supportsVision': 'no',
        });
        expect(restored.name, 'x');
        expect(restored.provider, LlmProvider.openAiCompatible);
        expect(restored.baseUrl, isEmpty);
        expect(restored.model, isEmpty);
        expect(restored.temperature, 1.0);
        expect(restored.headers, {'ok': 'yes'});
        expect(restored.enabled, isTrue);
        expect(restored.supportsVision, isFalse);
      });

      test('maps provider aliases', () {
        LlmProvider parse(String value) =>
            AiProviderConfig.fromJson({'id': 'x', 'provider': value}).provider;
        expect(parse('anthropic'), LlmProvider.anthropic);
        expect(parse('Claude'), LlmProvider.anthropic);
        expect(parse('google'), LlmProvider.gemini);
        expect(parse('gemini'), LlmProvider.gemini);
        expect(parse('ollama'), LlmProvider.ollama);
        expect(parse('open_ai_compatible'), LlmProvider.openAiCompatible);
      });

      test('throws without an id', () {
        expect(
          () => AiProviderConfig.fromJson(const {'name': 'x'}),
          throwsFormatException,
        );
        expect(
          () => AiProviderConfig.fromJson(const {'id': ''}),
          throwsFormatException,
        );
      });
    });

    group('copyWith', () {
      test('keeps the id and unspecified fields', () {
        final copy = full.copyWith(name: 'Renamed', apiKey: 'k2');
        expect(copy.id, 'abc');
        expect(copy.name, 'Renamed');
        expect(copy.apiKey, 'k2');
        expect(copy.model, full.model);
        expect(copy.headers, full.headers);
        expect(full.copyWith(), equals(full));
      });

      test('replaces every field', () {
        final copy = full.copyWith(
          provider: LlmProvider.ollama,
          baseUrl: 'http://localhost:11434',
          model: 'gemma3',
          presetId: 'ollama',
          effort: 'high',
          temperature: 1,
          headers: const {},
          enabled: true,
          supportsVision: false,
        );
        expect(copy.provider, LlmProvider.ollama);
        expect(copy.baseUrl, 'http://localhost:11434');
        expect(copy.model, 'gemma3');
        expect(copy.presetId, 'ollama');
        expect(copy.effort, 'high');
        expect(copy.temperature, 1);
        expect(copy.headers, isEmpty);
        expect(copy.enabled, isTrue);
        expect(copy.supportsVision, isFalse);
      });

      test('clears nullable fields on request', () {
        final copy = full.copyWith(
          clearApiKey: true,
          clearEffort: true,
          clearPresetId: true,
          clearTemperature: true,
        );
        expect(copy.apiKey, isNull);
        expect(copy.effort, isNull);
        expect(copy.presetId, isNull);
        expect(copy.temperature, isNull);
      });
    });

    test('equality covers headers and presetId', () {
      expect(full, equals(full.copyWith()));
      expect(full.hashCode, full.copyWith().hashCode);
      expect(full, isNot(equals(full.copyWith(headers: const {}))));
      expect(full, isNot(equals(full.copyWith(presetId: 'other'))));
      expect(full, isNot(equals(full.copyWith(apiKey: 'other'))));
      expect(full.toString(), isNot(contains('sk-secret')));
    });

    group('isLocal', () {
      const local = [
        'http://localhost:11434',
        'http://LOCALHOST:1234/v1',
        'http://foo.localhost',
        'http://127.0.0.1:8080/v1',
        'http://127.255.0.9',
        'http://10.0.0.5:1234/v1',
        'http://172.16.0.1',
        'http://172.31.255.255',
        'http://192.168.1.5:1234/v1',
        'http://169.254.10.10',
        'http://100.64.0.1:11434',
        'http://100.127.255.254',
        'http://0.0.0.0:8080',
        'http://[::1]:11434',
        'http://[fd7a:115c:a1e0::1]:11434',
        'http://[fe80::1]',
        'http://[::ffff:192.168.0.2]',
        'http://desktop.local:11434',
        'http://nas.lan/v1',
        'http://server.home.arpa',
        'http://box.internal',
        'http://my-pc.tail1234.ts.net:11434',
        'http://ollama:11434',
        'http://mypc',
        'localhost:1234/v1',
        '192.168.0.10:8080',
      ];
      const remote = [
        'https://api.openai.com/v1',
        'https://openrouter.ai/api/v1',
        'http://8.8.8.8',
        'http://172.15.0.1',
        'http://172.32.0.1',
        'http://100.63.0.1',
        'http://100.128.0.1',
        'http://192.169.0.1',
        'http://[2001:db8::1]',
        'http://[::ffff:8.8.8.8]',
        'https://example.com',
        'http://localhost.example.com',
        '',
        '   ',
      ];

      for (final url in local) {
        test('true for "$url"', () {
          expect(config(baseUrl: url).isLocal, isTrue);
        });
      }
      for (final url in remote) {
        test('false for "$url"', () {
          expect(config(baseUrl: url).isLocal, isFalse);
        });
      }

      test('isLocalHost handles brackets and trailing dots', () {
        expect(AiProviderConfig.isLocalHost('[::1]'), isTrue);
        expect(AiProviderConfig.isLocalHost('localhost.'), isTrue);
        expect(AiProviderConfig.isLocalHost('999.1.1.1'), isFalse);
        expect(AiProviderConfig.isLocalHost('example.org.'), isFalse);
        expect(AiProviderConfig.isLocalHost('gg::zz'), isFalse);
        expect(AiProviderConfig.isLocalHost(':1'), isFalse);
      });
    });

    group('toEndpoint', () {
      test('maps provider, base URL, key and headers', () {
        final endpoint = config(
          apiKey: 'sk-1',
          provider: LlmProvider.anthropic,
          headers: const {'X-Title': 'Mozhi'},
        ).toEndpoint();
        expect(endpoint.provider, LlmProvider.anthropic);
        expect(endpoint.baseUrl, Uri.parse('https://api.openai.com/v1'));
        expect(endpoint.apiKey, 'sk-1');
        expect(endpoint.headers, {'X-Title': 'Mozhi'});
      });

      test('omits empty keys', () {
        expect(config(apiKey: '').toEndpoint().apiKey, isNull);
        expect(config(apiKey: '  ').toEndpoint().apiKey, isNull);
        expect(config().toEndpoint().apiKey, isNull);
        expect(config(apiKey: ' k ').toEndpoint().apiKey, 'k');
      });

      test('normalises the base URL', () {
        expect(
          config(baseUrl: ' https://api.x.ai/v1/ ').toEndpoint().baseUrl,
          Uri.parse('https://api.x.ai/v1'),
        );
        expect(
          config(baseUrl: 'localhost:1234/v1').toEndpoint().baseUrl,
          Uri.parse('http://localhost:1234/v1'),
        );
        expect(
          config(baseUrl: 'api.example.com/v1').toEndpoint().baseUrl,
          Uri.parse('https://api.example.com/v1'),
        );
        expect(config(baseUrl: '').toEndpoint().baseUrl, Uri());
      });
    });
  });

  group(AiProviderPreset, () {
    test('includes the required presets', () {
      final ids = AiProviderPreset.all.map((p) => p.id).toList();
      expect(
        ids,
        containsAll(<String>[
          'openai',
          'anthropic',
          'gemini',
          'openrouter',
          'groq',
          'deepseek',
          'mistral',
          'xai',
          'together',
          'ollama',
          'lmstudio',
          'llamacpp',
          'custom',
        ]),
      );
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('every preset is well formed', () {
      for (final preset in AiProviderPreset.all) {
        expect(preset.name, isNotEmpty, reason: preset.id);
        expect(preset.description, isNotEmpty, reason: preset.id);
        if (preset.id != 'custom') {
          final uri = Uri.parse(preset.baseUrl);
          expect(uri.hasScheme, isTrue, reason: preset.id);
          expect(preset.baseUrl.endsWith('/'), isFalse, reason: preset.id);
        }
        if (preset.defaultModel.isNotEmpty) {
          expect(preset.suggestedModels, contains(preset.defaultModel));
        }
        if (preset.requiresApiKey) {
          expect(preset.apiKeyUrl, startsWith('https://'), reason: preset.id);
        }
        // The preset flag agrees with the URL heuristic.
        if (preset.baseUrl.isNotEmpty) {
          expect(
            preset.toConfig(id: 'x').isLocal,
            preset.isLocal,
            reason: preset.id,
          );
        }
      }
    });

    test('anthropic preset', () {
      final preset = AiProviderPreset.byId('anthropic')!;
      expect(preset.provider, LlmProvider.anthropic);
      expect(preset.baseUrl, 'https://api.anthropic.com/v1');
      expect(preset.defaultModel, 'claude-opus-5-5');
      expect(
        preset.suggestedModels,
        containsAll(['claude-sonnet-5-5', 'claude-haiku-5-5']),
      );
      expect(preset.defaultEffort, 'low');
    });

    test('gemini preset', () {
      final preset = AiProviderPreset.byId('gemini')!;
      expect(preset.provider, LlmProvider.gemini);
      expect(
        preset.baseUrl,
        'https://generativelanguage.googleapis.com/v1beta',
      );
      expect(preset.defaultModel, 'gemini-flash-latest');
    });

    test('openrouter preset sends attribution headers', () {
      final preset = AiProviderPreset.byId('openrouter')!;
      expect(preset.baseUrl, 'https://openrouter.ai/api/v1');
      expect(preset.headers, {
        'HTTP-Referer': 'https://github.com/Aimdi/Mozhi',
        'X-Title': 'Mozhi',
      });
      expect(preset.toConfig(id: 'x').toEndpoint().headers, preset.headers);
    });

    test('local presets', () {
      final ollama = AiProviderPreset.byId('ollama')!;
      expect(ollama.provider, LlmProvider.ollama);
      expect(ollama.baseUrl, 'http://localhost:11434');
      expect(ollama.requiresApiKey, isFalse);
      expect(ollama.isLocal, isTrue);

      expect(
        AiProviderPreset.byId('lmstudio')!.baseUrl,
        'http://localhost:1234/v1',
      );
      expect(
        AiProviderPreset.byId('llamacpp')!.baseUrl,
        'http://localhost:8080/v1',
      );
      final custom = AiProviderPreset.byId('custom')!;
      expect(custom.baseUrl, isEmpty);
      expect(custom.requiresApiKey, isFalse);
      expect(custom.provider, LlmProvider.openAiCompatible);
    });

    test('byId returns null for unknown ids', () {
      expect(AiProviderPreset.byId('nope'), isNull);
    });

    test('toConfig copies the preset', () {
      final cfg = AiProviderPreset.byId('anthropic')!
          .toConfig(id: 'id1', apiKey: 'key');
      expect(cfg.id, 'id1');
      expect(cfg.name, 'Anthropic');
      expect(cfg.presetId, 'anthropic');
      expect(cfg.effort, 'low');
      expect(cfg.model, 'claude-opus-5-5');
      expect(cfg.apiKey, 'key');

      final overridden = AiProviderPreset.byId('ollama')!.toConfig(
        id: 'id2',
        name: 'Home',
        model: 'qwen3',
        baseUrl: 'http://nas.lan:11434',
      );
      expect(overridden.name, 'Home');
      expect(overridden.model, 'qwen3');
      expect(overridden.baseUrl, 'http://nas.lan:11434');
    });
  });
}
