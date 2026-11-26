import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('dictionary', () {
    late Harness h;

    const sampleEntry = DictionaryEntry(
      word: 'chat',
      pronunciation: '/ʃa/',
      partsOfSpeech: ['noun'],
      didYouMean: 'chat',
      senses: [
        DictionarySense(
          definition: 'A small domesticated feline mammal.',
          partOfSpeech: 'noun',
          translations: ['cat', 'kitty'],
          usage: 'common',
        ),
      ],
      examples: [
        DictionaryExample(
          source: 'Le chat dort sur le canapé.',
          translation: 'The cat is sleeping on the sofa.',
        ),
      ],
      synonyms: ['félin', 'minou'],
      relatedWords: ['chaton', 'chatte'],
      etymology: 'From Late Latin cattus.',
      notes: 'Also used informally for online chat.',
    );

    setUp(() {
      h = Harness()
        ..writeConfig(
          const CliConfig(providers: [ProviderEntry(ollamaProvider)]),
        );
      when(
        () => h.repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenAnswer((_) async => sampleEntry);
    });

    tearDown(() => h.dispose());

    test('looks up a word and formats the terminal output', () async {
      final code = await h.run([
        'dictionary',
        '--from',
        'fr',
        '--to',
        'en',
        '--verbosity',
        'detailed',
        '--context',
        'pet animal',
        'chat',
      ]);
      expect(code, ExitCode.success.code);
      expect(h.stdout, contains('chat'));
      expect(h.stdout, contains('/ʃa/'));
      expect(h.stdout, contains('A small domesticated feline mammal.'));
      expect(h.stdout, contains('→ cat, kitty'));
      expect(h.stdout, contains('Le chat dort sur le canapé.'));
      expect(h.stdout, contains('Synonyms: félin, minou'));
      expect(h.stdout, contains('Related: chaton, chatte'));
      expect(h.stdout, contains('Etymology: From Late Latin cattus.'));
      expect(h.stdout, contains('Notes: Also used informally'));

      verify(
        () => h.repository.lookUp(
          any(
            that: isA<TranslationEngine>().having(
              (e) => e.id,
              'id',
              'ai:local',
            ),
          ),
          'chat',
          source: french,
          target: english,
          context: 'pet animal',
          verbosity: DictionaryVerbosity.comprehensive,
        ),
      ).called(1);
    });

    test('supports alias dict, stdin and --verbosity concise', () async {
      h.pipe('Maison\n');
      final code = await h.run(['dict', '--verbosity', 'concise']);
      expect(code, 0);
      verify(
        () => h.repository.lookUp(
          any(),
          'Maison',
          source: Language.auto,
          target: english,
          verbosity: DictionaryVerbosity.concise,
        ),
      ).called(1);
    });

    test('prints JSON with --json', () async {
      final code = await h.run(['dictionary', '--json', 'chat']);
      expect(code, 0);
      expect(h.json(), {
        'word': 'chat',
        'pronunciation': '/ʃa/',
        'partsOfSpeech': ['noun'],
        'didYouMean': 'chat',
        'senses': [
          {
            'definition': 'A small domesticated feline mammal.',
            'partOfSpeech': 'noun',
            'translations': ['cat', 'kitty'],
            'usage': 'common',
          },
        ],
        'examples': [
          {
            'source': 'Le chat dort sur le canapé.',
            'translation': 'The cat is sleeping on the sofa.',
          },
        ],
        'synonyms': ['félin', 'minou'],
        'relatedWords': ['chaton', 'chatte'],
        'etymology': 'From Late Latin cattus.',
        'notes': 'Also used informally for online chat.',
      });
    });

    test('rejects Mozhi and MT engines and missing AI providers', () async {
      expect(
        await h.run(['dictionary', '-e', 'google', 'chat']),
        ExitCode.usage.code,
      );
      expect(h.stderr, contains('Dictionary lookup needs an AI provider'));

      h
        ..writeConfig(
          const CliConfig(providers: [ProviderEntry(deeplMtProvider)]),
        )
        ..err.clear();
      expect(await h.run(['dictionary', 'chat']), ExitCode.usage.code);
      expect(h.stderr, contains('none is configured'));
    });
  });
}
