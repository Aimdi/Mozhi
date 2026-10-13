import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('languages', () {
    late Harness h;

    setUp(() {
      h = Harness();
      when(() => h.repository.getTargetLanguages(any())).thenAnswer(
        (_) async => const [
          Language(code: 'en', name: 'English', nativeName: 'English'),
          Language(code: 'fr', name: 'French', nativeName: 'Français'),
        ],
      );
      when(() => h.repository.getSourceLanguages(any()))
          .thenAnswer((_) async => [Language.auto, english]);
    });

    tearDown(() => h.dispose());

    test('lists target languages of the default engine', () async {
      when(() => h.console.stdoutHasTerminal).thenReturn(true);
      expect(await h.run(['languages']), 0);
      expect(h.stdout, contains('Français'));
      expect(h.stderr, contains('2 target languages (Google)'));
      final engine =
          verify(() => h.repository.getTargetLanguages(captureAny()))
                  .captured
                  .single
              as TranslationEngine;
      expect(engine.id, 'mozhi:google');
    });

    test('filters by code, name or native name', () async {
      expect(await h.run(['languages', '--json', 'franç']), 0);
      expect(h.json(), [
        {'code': 'fr', 'name': 'French', 'nativeName': 'Français'},
      ]);
    });

    test('reports when nothing matches', () async {
      expect(await h.run(['languages', 'xyz']), 0);
      expect(h.stdout, contains('No Google language matches "xyz"'));
    });

    test('lists source languages', () async {
      expect(await h.run(['languages', '--source', '--json']), 0);
      expect(h.json(), [
        {'code': 'auto', 'name': 'Detect language'},
        {'code': 'en', 'name': 'English'},
      ]);
    });

    test('mentions free-form targets for AI engines', () async {
      h.writeConfig(
        const CliConfig(providers: [ProviderEntry(ollamaProvider)]),
      );
      when(() => h.console.stdoutHasTerminal).thenReturn(true);
      expect(await h.run(['languages', '-e', 'ai']), 0);
      expect(h.stderr, contains('Pirate speak'));
    });
  });
}
