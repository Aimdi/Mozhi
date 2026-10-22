import 'dart:async';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const _en = Language(code: 'en', name: 'English');
const _de = Language(code: 'de', name: 'German');
const _fr = Language(code: 'fr', name: 'French');

/// A [DetailedOfflineTranslator] answering [answer], recording its calls.
class _Detailed implements DetailedOfflineTranslator {
  @override
  bool isAvailable = true;

  @override
  Set<String> supportedLanguages = {'en', 'de'};

  /// What [identifyLanguage] answers.
  String? identified;

  /// Translations wait for it when set.
  Completer<void>? gate;

  OfflineTranslation Function(String text) answer = (text) =>
      OfflineTranslation(text: '[$text]');

  final calls =
      <({String text, String source, String target, bool detailed})>[];
  final aborts = <Future<void>?>[];

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  }) async {
    calls.add((text: text, source: source, target: target, detailed: false));
    aborts.add(abort);
    await gate?.future;
    return answer(text).text;
  }

  @override
  Future<OfflineTranslation> translateDetailed(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  }) async {
    calls.add((text: text, source: source, target: target, detailed: true));
    aborts.add(abort);
    await gate?.future;
    return answer(text);
  }

  @override
  Future<bool> preload({
    required String source,
    required String target,
  }) async => false;

  @override
  Future<Set<String>> downloadedLanguages() async => supportedLanguages;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String?> identifyLanguage(String text) async => identified;

  @override
  Future<void> dispose() async {}
}

/// An [OfflineTranslator] without the detailed extras.
class _Plain implements OfflineTranslator {
  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'de'};

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async => '<$text>';

  @override
  Future<Set<String>> downloadedLanguages() async => supportedLanguages;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

/// "Hello world" -> [text] with Hallo <- Hello and Welt <- world.
OfflineTranslation _helloWorld(String text) {
  final hallo = text.indexOf('Hallo');
  final welt = text.indexOf('Welt');
  return OfflineTranslation(
    text: text,
    sentences: [
      OfflineSentence(
        sourceStart: 0,
        sourceEnd: 11,
        targetStart: 0,
        targetEnd: text.length,
        words: [
          OfflineWord(
            targetStart: hallo,
            targetEnd: hallo + 5,
            sourceStart: 0,
            sourceEnd: 5,
            alignment: 0.98,
          ),
          OfflineWord(
            targetStart: welt,
            targetEnd: welt + 4,
            sourceStart: 6,
            sourceEnd: 11,
            alignment: 0.95,
          ),
        ],
      ),
    ],
  );
}

void main() {
  final engine = TranslationEngine.offline();

  group('translate with the on-device engine', () {
    test('cancelling the stream completes the abort it passed on', () async {
      final translator = _Detailed()..gate = Completer();
      final repository = TranslationRepository(offline: translator);

      final subscription = repository
          .translate(
            engine,
            const TranslationRequest(text: 'Hello', source: _en, target: _de),
          )
          .listen((_) => fail('cancelled'));
      await pumpEventQueue();
      final abort = translator.aborts.single!;
      var aborted = false;
      unawaited(abort.then((_) => aborted = true));
      expect(aborted, isFalse);

      await subscription.cancel();
      await pumpEventQueue();

      expect(aborted, isTrue);
      expect(translator.calls.single.detailed, isFalse);
      translator.gate!.complete();
      await pumpEventQueue();
    });

    test('delivers the translation', () async {
      final translator = _Detailed();
      final repository = TranslationRepository(offline: translator);

      final result = await repository
          .translate(
            engine,
            const TranslationRequest(
              text: 'Good day',
              source: _en,
              target: _de,
            ),
          )
          .first;

      expect(result.text, '[Good day]');
      expect(result.engineId, engine.id);
      expect(translator.calls.single, (
        text: 'Good day',
        source: 'en',
        target: 'de',
        detailed: false,
      ));
    });

    test('translators without abort still translate', () async {
      final repository = TranslationRepository(offline: _Plain());

      final result = await repository
          .translate(
            engine,
            const TranslationRequest(text: 'Bye', source: _en, target: _de),
          )
          .first;

      expect(result.text, '<Bye>');
    });

    test(
      'translateOffline without an abort calls the translator as is',
      () async {
        final translator = _Detailed();
        final repository = TranslationRepository(offline: translator);
        // Through align's language handling there is no abort; check the
        // plain call keeps it null too.
        await repository.align(
          engine,
          source: 'Hello world',
          translation: '[Hello world]',
          sourceLanguage: _en,
          targetLanguage: _de,
        );

        expect(translator.aborts.single, isNull);
      },
    );
  });

  group('align with the on-device engine', () {
    late _Detailed translator;
    late TranslationRepository repository;

    setUp(() {
      translator = _Detailed()..answer = (_) => _helloWorld('Hallo Welt');
      repository = TranslationRepository(offline: translator);
    });

    Future<List<AlignedSpan>> align(
      String translation, {
      String source = 'Hello world',
      Language from = _en,
      Language to = _de,
    }) => repository.align(
      engine,
      source: source,
      translation: translation,
      sourceLanguage: from,
      targetLanguage: to,
    );

    test('aligns the words of its own translation', () async {
      expect(await align('Hallo Welt'), const [
        AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 5),
        AlignedSpan(
          sourceStart: 6,
          sourceEnd: 11,
          targetStart: 6,
          targetEnd: 10,
        ),
      ]);
      expect(translator.calls.single, (
        text: 'Hello world',
        source: 'en',
        target: 'de',
        detailed: true,
      ));
    });

    test('finds the words again in another translation', () async {
      expect(await align('Hallo, schöne Welt'), const [
        AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 5),
        AlignedSpan(
          sourceStart: 6,
          sourceEnd: 11,
          targetStart: 14,
          targetEnd: 18,
        ),
      ]);
      expect(await align('Servus'), isEmpty);
    });

    test('matches whole words only, in order', () async {
      translator.answer = (_) => const OfflineTranslation(
        text: 'es ist',
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 5,
            targetStart: 0,
            targetEnd: 6,
            words: [
              OfflineWord(
                targetStart: 0,
                targetEnd: 2,
                sourceStart: 0,
                sourceEnd: 2,
                alignment: 0.9,
              ),
              OfflineWord(
                targetStart: 3,
                targetEnd: 6,
                sourceStart: 3,
                sourceEnd: 5,
                alignment: 0.9,
              ),
            ],
          ),
        ],
      );

      final spans = await align('des: es ist', source: 'it is');

      expect([for (final s in spans) s.targetIn('des: es ist')], ['es', 'ist']);
      expect(spans.first.targetStart, 5);
    });

    test('identifies an auto source', () async {
      translator.identified = 'en';

      expect(await align('Hallo Welt', from: Language.auto), hasLength(2));
      expect(translator.calls.single.source, 'en');
    });

    test('takes the only downloaded language for an unknown source', () async {
      expect(await align('Hallo Welt', from: Language.auto), hasLength(2));
      expect(translator.calls.single.source, 'en');
    });

    test('blank texts and the same language give nothing', () async {
      expect(await align('  '), isEmpty);
      expect(await align('Hallo Welt', source: ' '), isEmpty);
      expect(await align('Hello world', to: _en), isEmpty);
      expect(translator.calls, isEmpty);
    });

    test('language errors are those of the on-device engine', () async {
      await expectLater(
        align('Bonjour', to: _fr),
        throwsA(isA<OfflineLanguageUnsupportedException>()),
      );
    });

    test('needs a translator that can align', () async {
      final plain = TranslationRepository(offline: _Plain());

      await expectLater(
        plain.align(
          engine,
          source: 'Hello',
          translation: 'Hallo',
          sourceLanguage: _en,
          targetLanguage: _de,
        ),
        throwsArgumentError,
      );
    });
  });

  group('low-confidence sentences with the on-device engine', () {
    late _Detailed translator;
    late TranslationRepository repository;

    /// "Good day. Bad dog." -> "Guten Tag. Böser Hund." with the second
    /// sentence unsure (the engine's text is [text]).
    OfflineTranslation unsure(String text) {
      final second = text.indexOf('Böser');
      return OfflineTranslation(
        text: text,
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 9,
            targetStart: 0,
            targetEnd: second,
            score: -0.1,
          ),
          OfflineSentence(
            sourceStart: 10,
            sourceEnd: 18,
            targetStart: second,
            targetEnd: text.length,
            score: -0.6,
            isLowConfidence: true,
          ),
        ],
      );
    }

    setUp(() {
      translator = _Detailed()
        ..answer = (_) => unsure('Guten Tag. Böser Hund.');
      repository = TranslationRepository(offline: translator);
    });

    Future<List<AlignedSpan>> uncertain(
      String translation, {
      String source = 'Good day. Bad dog.',
      Language from = _en,
      Language to = _de,
    }) => repository.lowConfidenceSentences(
      engine,
      source: source,
      translation: translation,
      sourceLanguage: from,
      targetLanguage: to,
    );

    test('finds the unsure sentences of its own translation', () async {
      expect(await uncertain('Guten Tag. Böser Hund.'), const [
        AlignedSpan(
          sourceStart: 10,
          sourceEnd: 18,
          targetStart: 11,
          targetEnd: 22,
        ),
      ]);
      expect(translator.calls.single, (
        text: 'Good day. Bad dog.',
        source: 'en',
        target: 'de',
        detailed: true,
      ));
    });

    test('leaves the whitespace around a sentence out', () async {
      translator.answer = (_) => const OfflineTranslation(
        text: 'Hallo.  Welt? ',
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 6,
            targetStart: 6,
            targetEnd: 14,
            isLowConfidence: true,
          ),
          OfflineSentence(
            sourceStart: 6,
            sourceEnd: 7,
            targetStart: 14,
            targetEnd: 14,
            isLowConfidence: true,
          ),
        ],
      );

      final spans = await uncertain('Hallo.  Welt? ', source: 'Hello. World?');

      expect([for (final s in spans) s.targetIn('Hallo.  Welt? ')], ['Welt?']);
    });

    test('finds the sentences again in another translation', () async {
      const shown = 'Schönen Tag. Böser Hund.';
      final spans = await uncertain(shown);

      expect([for (final s in spans) s.targetIn(shown)], ['Böser Hund.']);
      expect(spans.single.sourceStart, 10);
      expect(await uncertain('Guten Tag. Lieber Hund.'), isEmpty);
    });

    test('looks the sentences up in order', () async {
      translator.answer = (_) => const OfflineTranslation(
        text: 'Ja. Ja.',
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 4,
            targetStart: 0,
            targetEnd: 3,
            isLowConfidence: true,
          ),
          OfflineSentence(
            sourceStart: 5,
            sourceEnd: 9,
            targetStart: 4,
            targetEnd: 7,
            isLowConfidence: true,
          ),
        ],
      );

      final spans = await uncertain('Nun: Ja. Ja.', source: 'Yes. Yes.');

      expect([for (final s in spans) s.targetStart], [5, 9]);
    });

    test('nothing is unsure in a confident translation', () async {
      translator.answer = _helloWorld;

      expect(await uncertain('Hallo Welt', source: 'Hello world'), isEmpty);
    });

    test('blank texts and the same language give nothing', () async {
      expect(await uncertain('  '), isEmpty);
      expect(await uncertain('Guten Tag.', source: ' '), isEmpty);
      expect(await uncertain('Good day.', to: _en), isEmpty);
      expect(translator.calls, isEmpty);
    });

    test('translators without details cannot tell', () async {
      final plain = TranslationRepository(offline: _Plain());

      expect(
        await plain.lowConfidenceSentences(
          engine,
          source: 'Hello',
          translation: 'Hallo',
          sourceLanguage: _en,
          targetLanguage: _de,
        ),
        isEmpty,
      );
    });

    test('only the on-device engine can tell', () async {
      await expectLater(
        repository.lowConfidenceSentences(
          const TranslationEngine(
            id: 'mozhi:google',
            kind: EngineKind.mozhi,
            name: 'Google',
            mozhiEngine: 'google',
          ),
          source: 'Hello',
          translation: 'Hallo',
          sourceLanguage: _en,
          targetLanguage: _de,
        ),
        throwsArgumentError,
      );
      expect(translator.calls, isEmpty);
    });

    test('language errors are those of the on-device engine', () async {
      await expectLater(
        uncertain('Bonjour', to: _fr),
        throwsA(isA<OfflineLanguageUnsupportedException>()),
      );
    });
  });
}
