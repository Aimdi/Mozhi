import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/repository/mt_engines.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  group(MtEngines, () {
    late List<MockDeeplClient> built;
    late MtEngines engines;

    setUp(() {
      built = [];
      engines = MtEngines(
        deepl: (config) {
          final client = MockDeeplClient();
          when(() => client.languages(type: any(named: 'type')))
              .thenAnswer((_) async => const []);
          built.add(client);
          return client;
        },
      );
    });

    test('replaces a client whose connection changed', () async {
      await engines.targetLanguages(deeplConfig);
      await engines.targetLanguages(deeplConfig.copyWith(apiKey: 'new:fx'));
      expect(built, hasLength(2));
      verify(built.first.close).called(1);
      verifyNever(built.last.close);
    });

    test('rejects LLM providers', () async {
      await expectLater(
        engines.sourceLanguages(claudeConfig),
        throwsArgumentError,
      );
      await expectLater(
        engines.targetLanguages(claudeConfig),
        throwsArgumentError,
      );
      await expectLater(
        engines.translate(
          aiEngine(claudeConfig),
          claudeConfig,
          const TranslationRequest(
            text: 'Hello',
            source: english,
            target: german,
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(engines.test(claudeConfig), throwsArgumentError);
      expect(built, isEmpty);
    });

    test('connectionKey covers the service, URL and key', () {
      final key = MtEngines.connectionKey(deeplConfig);
      expect(MtEngines.connectionKey(deeplConfig.copyWith(name: 'x')), key);
      expect(
        MtEngines.connectionKey(deeplConfig.copyWith(apiKey: 'other')),
        isNot(key),
      );
      expect(
        MtEngines.connectionKey(deeplConfig.copyWith(baseUrl: 'proxy')),
        isNot(key),
      );
      expect(
        MtEngines.connectionKey(
          deeplConfig.copyWith(service: MtService.libreTranslate),
        ),
        isNot(key),
      );
    });
  });
}
