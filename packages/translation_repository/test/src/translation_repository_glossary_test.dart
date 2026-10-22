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
          .translate(googleEngine, german('Das Haus und die Häuser sind alt'))
          .single;
      expect(sent.single, 'Das ⟨1⟩ und die ⟨1⟩ sind alt');
      expect(result.text, 'The building and the building are old');
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
