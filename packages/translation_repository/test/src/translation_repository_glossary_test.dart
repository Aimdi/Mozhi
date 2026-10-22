import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

/// Glossaries applied on the device for engines that cannot apply them
/// (Mozhi engines, LibreTranslate): the terms go as tokens, the renderings
/// come back in their place.
void main() {
  setUpAll(registerTestFallbacks);

  late MockMozhiApiClient mozhi;
  late MockLibreTranslateClient libre;
  late TranslationRepository repository;
  final sent = <String>[];

  setUp(() {
    mozhi = MockMozhiApiClient();
    libre = MockLibreTranslateClient();
    sent.clear();
    repository =
        allowNetwork(
          TranslationRepository(
            mozhiClientFactory: (_) => mozhi,
            libreTranslateClientFactory: (_) => libre,
            snapshotInterval: Duration.zero,
          ),
        )..updateConfiguration(
          instances: const [instanceA],
          providers: const [libreConfig, deeplConfig],
        );
    addTearDown(repository.dispose);
  });

  /// Mozhi answers each text with [answer] of it.
  void stubMozhi(String Function(String text) answer) =>
      when(
        () => mozhi.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).thenAnswer((invocation) async {
        final text = invocation.namedArguments[#text] as String;
        sent.add(text);
        return MozhiTranslation(
          engine: invocation.namedArguments[#engine] as String,
          translatedText: answer(text),
        );
      });

  String toEnglish(String text) => text
      .replaceAll('Das', 'The')
      .replaceAll('und die', 'and the')
      .replaceAll('ist groß', 'is big')
      .replaceAll('sind alt', 'are old');

  TranslationRequest german(
    String text, {
    Map<String, String> glossary = const {'Haus': 'building'},
    bool preserveFormatting = true,
  }) => TranslationRequest(
    text: text,
    source: const Language(code: 'de', name: 'German'),
    target: english,
    options: TranslationOptions(
      glossary: glossary,
      preserveFormatting: preserveFormatting,
    ),
  );

  group('Mozhi engines', () {
    test('send the terms as tokens and put the renderings back', () async {
      stubMozhi(toEnglish);
      final result = await repository
          .translate(googleEngine, german('Das Haus und die HAUS sind alt'))
          .single;
      expect(sent.single, 'Das ⟨1⟩ und die ⟨1⟩ sind alt');
      expect(result.text, 'The building and the building are old');
      expect(result.warnings, isEmpty);
    });

    test('replace whole words only, not other forms', () async {
      stubMozhi(toEnglish);
      final result = await repository
          .translate(googleEngine, german('Das Haus und die Häuser sind alt'))
          .single;
      expect(sent.single, 'Das ⟨1⟩ und die Häuser sind alt');
      expect(result.text, 'The building and the Häuser are old');
      expect(result.warnings, isEmpty);
    });

    test('capitalise a rendering that starts a sentence', () async {
      stubMozhi((text) => text.replaceAll('ist groß', 'is big'));
      final result = await repository
          .translate(googleEngine, german('Haus ist groß'))
          .single;
      expect(result.text, 'Building is big');
    });

    test('mask personal data and formatting alongside', () async {
      stubMozhi(toEnglish);
      final result = await repository
          .translate(
            googleEngine,
            german('Das Haus <b>jane@x.org</b> ist groß'),
          )
          .single;
      expect(sent.single, 'Das ⟨1⟩ ⟨2⟩⟨3⟩⟨4⟩ ist groß');
      expect(result.text, 'The building <b>jane@x.org</b> is big');
      expect(result.maskedPersonalData, 1);
    });

    test('also apply the glossary without formatting masks', () async {
      stubMozhi(toEnglish);
      final result = await repository
          .translate(
            googleEngine,
            german('Das Haus ist groß', preserveFormatting: false),
          )
          .single;
      expect(sent.single, 'Das ⟨1⟩ ist groß');
      expect(result.text, 'The building is big');
    });

    test(
      'a lost term is sent again without the glossary and reported',
      () async {
        stubMozhi(
          (text) => text.contains('⟨1⟩')
              ? 'The is big'
              : toEnglish(text).replaceAll('Haus', 'house'),
        );
        final result = await repository
            .translate(googleEngine, german('Das Haus ist groß'))
            .single;
        expect(sent, ['Das ⟨1⟩ ist groß', 'Das Haus ist groß']);
        expect(result.text, 'The house is big');
        final warning = result.warnings.singleWhere(
          (w) => w.kind == TranslationWarningKind.glossary,
        );
        expect(warning.items, ['building']);
      },
    );

    test('a lost term keeps personal data masked on the second try', () async {
      stubMozhi((text) => text.startsWith('Das ⟨1⟩ ⟨2⟩') ? 'The is big' : text);
      await repository
          .translate(
            googleEngine,
            german('Das Haus jane@x.org ist groß', preserveFormatting: false),
          )
          .drain<void>();
      expect(sent, ['Das ⟨1⟩ ⟨2⟩ ist groß', 'Das Haus ⟨1⟩ ist groß']);
    });

    test('without terms in the text, nothing is masked', () async {
      stubMozhi(toEnglish);
      final result = await repository
          .translate(googleEngine, german('Das ist groß'))
          .single;
      expect(sent.single, 'Das ist groß');
      expect(result.warnings, isEmpty);
    });
  });

  group('words that only look like a term', () {
    /// The English [text] with [glossary], into Spanish.
    TranslationRequest english(
      String text,
      Map<String, String> glossary, {
      Set<String> caseSensitive = const {},
      bool preserveFormatting = true,
    }) => TranslationRequest(
      text: text,
      source: const Language(code: 'en', name: 'English'),
      target: const Language(code: 'es', name: 'Spanish'),
      options: TranslationOptions(
        glossary: glossary,
        caseSensitiveGlossaryTerms: caseSensitive,
        preserveFormatting: preserveFormatting,
      ),
    );

    Iterable<TranslationWarning> glossaryWarnings(TranslationResult result) =>
        result.warnings.where(
          (warning) => warning.kind == TranslationWarningKind.glossary,
        );

    /// What Mozhi gets and the result of [text] with [glossary], Mozhi
    /// echoing what it gets.
    Future<(String, TranslationResult)> echo(
      String text,
      Map<String, String> glossary, {
      Set<String> caseSensitive = const {},
      bool preserveFormatting = true,
    }) async {
      sent.clear();
      stubMozhi((text) => text);
      final result = await repository
          .translate(
            googleEngine,
            english(
              text,
              glossary,
              caseSensitive: caseSensitive,
              preserveFormatting: preserveFormatting,
            ),
          )
          .single;
      return (sent.single, result);
    }

    for (final (glossary, text) in [
      (const {'IT': 'TI'}, 'Is it ready?'),
      (const {'US': 'EE. UU.'}, 'Tell us more.'),
      (const {'Apple': 'Apple'}, 'He applied today.'),
      (const {'Paris': 'París'}, 'Parity in the parish.'),
      (const {'car': 'coche'}, 'He cares a lot.'),
      (const {'Mail': 'correo'}, 'Wir fliegen nach Mailand.'),
      (const {'Bank': 'banco'}, 'Das Bankett beginnt.'),
    ]) {
      test('are sent and come back as they are: $text', () async {
        final (masked, result) = await echo(text, glossary);
        expect(masked, text);
        expect(result.text, text);
        expect(glossaryWarnings(result), isEmpty);
      });
    }

    test('acronyms are replaced in their exact case', () async {
      final (masked, result) = await echo('Is it in the IT budget?', {
        'IT': 'TI',
      });
      expect(masked, 'Is it in the ⟨1⟩ budget?');
      expect(result.text, 'Is it in the TI budget?');
      expect(glossaryWarnings(result), isEmpty);
    });

    test('other terms in any case, multi-word ones too', () async {
      final (masked, result) = await echo(
        'Glossary of machine learning: see the glossary.',
        {'glossary': 'glosario', 'machine learning': 'aprendizaje automático'},
      );
      expect(masked, '⟨1⟩ of ⟨2⟩: see the ⟨1⟩.');
      expect(
        result.text,
        'Glosario of aprendizaje automático: see the glosario.',
      );
    });

    test('case-sensitive terms in their exact case only', () async {
      final (masked, result) = await echo(
        'Apple sells no apple.',
        {'Apple': 'Apple Inc.'},
        caseSensitive: {'Apple'},
      );
      expect(masked, '⟨1⟩ sells no apple.');
      expect(result.text, 'Apple Inc. sells no apple.');
    });

    test('never inside URLs or e-mail addresses', () async {
      repository.maskPersonalData = false;
      final (masked, result) = await echo(
        'The bank: https://bank.example/bank or bank@example.org',
        {'bank': 'banco'},
        preserveFormatting: false,
      );
      expect(masked, '⟨1⟩: https://bank.example/bank or bank@example.org');
      expect(
        result.text,
        'Banco: https://bank.example/bank or bank@example.org',
      );
      expect(glossaryWarnings(result), isEmpty);
    });
  });

  test('LibreTranslate gets the terms as tokens', () async {
    when(libre.languages).thenAnswer((_) async => const []);
    when(
      () => libre.translate(
        text: any(named: 'text'),
        target: any(named: 'target'),
        source: any(named: 'source'),
        abortTrigger: any(named: 'abortTrigger'),
      ),
    ).thenAnswer((invocation) async {
      final text = invocation.namedArguments[#text] as String;
      sent.add(text);
      return LibreTranslation(text: toEnglish(text));
    });
    final result = await repository
        .translate(mtEngine(libreConfig), german('Das Haus ist groß'))
        .single;
    expect(sent.single, 'Das ⟨1⟩ ist groß');
    expect(result.text, 'The building is big');
  });

  test('which engines apply glossaries', () {
    expect(googleEngine.supportsGlossary, isTrue);
    expect(mtEngine(libreConfig).supportsGlossary, isTrue);
    expect(mtEngine(deeplConfig).supportsGlossary, isTrue);
    expect(aiEngine(claudeConfig).supportsGlossary, isTrue);
    expect(aiEngine(gemmaConfig).supportsGlossary, isFalse);
    expect(TranslationEngine.offline().supportsGlossary, isFalse);
  });
}
