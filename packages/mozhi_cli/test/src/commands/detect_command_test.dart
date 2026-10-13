import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('detect', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    test('detects with the Mozhi instance', () async {
      when(() => h.repository.detectLanguage(any()))
          .thenAnswer((_) async => const DetectedLanguage(code: 'fr'));
      expect(await h.run(['detect', 'Bonjour']), 0);
      expect(h.out, ['fr\tFrench']);
    });

    test('uses an AI engine and prints JSON', () async {
      h.writeConfig(
        const CliConfig(providers: [ProviderEntry(ollamaProvider)]),
      );
      when(
        () => h.repository.detectLanguage(any(), engine: any(named: 'engine')),
      ).thenAnswer(
        (_) async => const DetectedLanguage(
          code: 'sr-Latn',
          isUncertain: true,
          isMixed: true,
          alternatives: ['hr', 'bs'],
        ),
      );
      expect(await h.run(['detect', '-e', 'ai', '--json', 'Zdravo']), 0);
      expect(h.json(), {
        'code': 'sr-Latn',
        'name': 'Serbian (Latin)',
        'uncertain': true,
        'mixed': true,
        'alternatives': ['hr', 'bs'],
      });
      final engine =
          verify(
                () => h.repository.detectLanguage(
                  'Zdravo',
                  engine: captureAny(named: 'engine'),
                ),
              ).captured.single
              as TranslationEngine;
      expect(engine.id, 'ai:local');
    });

    test('marks uncertain results', () async {
      when(() => h.repository.detectLanguage(any())).thenAnswer(
        (_) async => const DetectedLanguage(
          code: 'xx',
          isUncertain: true,
          isMixed: true,
        ),
      );
      expect(await h.run(['detect', '-e', 'google', 'x']), 0);
      expect(h.out, ['xx\txx (uncertain) (mixed)']);
    });
  });
}
