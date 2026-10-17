import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_models.dart';

class _MockEngine extends Mock implements BergamotEngine;

/// A native identifier answering [detection] (null: none here) or throwing
/// [error], recording the texts it saw.
class _FakeLanguageId implements NativeLanguageIdentifier {
  Cld2Detection? detection;
  Exception? error;
  final texts = <String>[];

  @override
  Future<Cld2Detection?> identify(
    String text, {
    List<String> hints = const [],
  }) async {
    texts.add(text);
    if (error case final error?) throw error;
    return detection;
  }
}

Cld2Detection _detection(String precise, {String? guess, int score = 1500}) =>
    Cld2Detection(
      precise: Cld2Result(
        language: precise,
        languages: [
          if (precise != 'un') Cld2Language(precise, percent: 95, score: score),
        ],
        reliable: precise != 'un',
      ),
      bestEffort: Cld2Result(
        language: guess ?? precise,
        languages: [Cld2Language(guess ?? precise, percent: 90, score: score)],
        reliable: true,
      ),
    );

void main() {
  setUpAll(() => registerFallbackValue(<ModelPaths>[]));

  late Directory root;
  late List<FakeModel> models;
  late FakeModelServer server;
  late _MockEngine engine;
  late _FakeLanguageId languageId;
  late bool metered;
  late BergamotTranslator translator;

  BergamotTranslator create({bool? isAvailable = true, int chunk = 2000}) =>
      BergamotTranslator(
        catalog: catalogOf(models),
        root: root,
        httpClient: server.client,
        engine: engine,
        languageId: languageId,
        isAvailable: isAvailable,
        isMeteredConnection: () async => metered,
        maxChunkLength: chunk,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('bergamot_translator_');
    models = [
      FakeModel('en', 'de'),
      FakeModel('de', 'en'),
      FakeModel('es', 'en'),
      FakeModel('en', 'es'),
      FakeModel('en', 'az'),
      FakeModel('hbs', 'en'),
      FakeModel('en', 'hr'),
      FakeModel('en', 'bs'),
    ];
    server = FakeModelServer(models);
    engine = _MockEngine();
    languageId = _FakeLanguageId();
    metered = false;
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    when(
      () => engine.translate(any(), any(), html: any(named: 'html')),
    ).thenAnswer((invocation) async {
      final chain = invocation.positionalArguments[0] as List<ModelPaths>;
      final text = invocation.positionalArguments[1] as String;
      return '[${chain.map((p) => p.key.split('/').first).join('|')}] $text';
    });
    translator = create();
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('availability', () {
    test('follows the override', () {
      expect(translator.isAvailable, isTrue);
      expect(create(isAvailable: false).isAvailable, isFalse);
    });

    test('creates its own engine and manager by default', () async {
      final defaults = BergamotTranslator(
        catalog: catalogOf(models),
        root: root,
        isMeteredConnection: () async => false,
      );
      expect(defaults.engine, isNotNull);
      expect(defaults.models.root, root);
      await defaults.dispose();
      defaults.models.close();
    });

    test('defaults to the platform check (false in tests)', () {
      expect(create(isAvailable: null).isAvailable, isFalse);
      expect(BergamotTranslator.isPlatformSupported, isFalse);
    });

    test('unavailable: nothing downloaded, operations throw', () async {
      final off = create(isAvailable: false);
      expect(await off.downloadedLanguages(), isEmpty);
      expect(() => off.downloadLanguage('de'), throwsUnsupportedError);
      expect(() => off.deleteLanguage('de'), throwsUnsupportedError);
      expect(
        () => off.translate('Hi', source: 'en', target: 'de'),
        throwsUnsupportedError,
      );
    });
  });

  test('languages', () {
    expect(translator.supportedLanguages, {'en', 'de', 'es', 'hr', 'bs'});
    expect(translator.targetLanguages, contains('az'));
    expect(translator.sourceLanguages, isNot(contains('az')));
  });

  group('downloadLanguage', () {
    test('installs both directions', () async {
      final progress = <ModelDownloadProgress>[];
      translator.downloadProgress.listen(progress.add);
      expect(translator.downloadSize('de'), greaterThan(0));
      await translator.downloadLanguage('de');
      expect((await translator.models.installed()).map((m) => m.pair), [
        'de-en',
        'en-de',
      ]);
      expect(await translator.downloadedLanguages(), {'en', 'de'});
      expect(await translator.installedSize(), greaterThan(0));
      expect(progress, isNotEmpty);
    });

    test('target-only languages install one direction', () async {
      await translator.downloadLanguage('az');
      expect(await translator.downloadedLanguages(), {'en', 'az'});
    });

    test('English needs nothing', () async {
      await translator.downloadLanguage('en');
      await translator.downloadLanguage('en-US');
      expect(server.requests, isEmpty);
      expect(await translator.downloadedLanguages(), {'en'});
    });

    test('refuses a metered connection with wifiOnly', () async {
      metered = true;
      await expectLater(
        translator.downloadLanguage('de'),
        throwsA(isA<MeteredConnectionException>()),
      );
      expect(server.requests, isEmpty);
      expect(
        const MeteredConnectionException().toString(),
        contains('Metered'),
      );
      await translator.downloadLanguage('de', wifiOnly: false);
      expect(await translator.downloadedLanguages(), contains('de'));
    });

    test('does not ask about the network when already installed', () async {
      await translator.downloadLanguage('de');
      metered = true;
      await translator.downloadLanguage('de');
    });

    test('rejects unsupported languages', () {
      expect(
        () => translator.downloadLanguage('fr'),
        throwsA(isA<OfflineLanguageUnsupportedException>()),
      );
    });
  });

  group('deleteLanguage', () {
    test('releases loaded models and deletes both directions', () async {
      await translator.downloadLanguage('de');
      await translator.deleteLanguage('de');
      verify(() => engine.release('de-en/run1')).called(1);
      verify(() => engine.release('en-de/run1')).called(1);
      expect(await translator.models.installed(), isEmpty);
      expect(await translator.downloadedLanguages(), {'en'});
    });

    test('keeps models another language still needs', () async {
      await translator.downloadLanguage('hr');
      await translator.downloadLanguage('bs');
      await translator.deleteLanguage('hr');
      expect((await translator.models.installed()).map((m) => m.pair), [
        'en-bs',
        'hbs-en',
      ]);
      expect(await translator.downloadedLanguages(), {'en', 'bs'});
    });

    test('English is a no-op, unknown languages throw', () async {
      await translator.deleteLanguage('en');
      expect(
        () => translator.deleteLanguage('fr'),
        throwsA(isA<OfflineLanguageUnsupportedException>()),
      );
    });
  });

  group('translate', () {
    test('uses the direct model', () async {
      await translator.downloadLanguage('de');
      expect(
        await translator.translate('Hello', source: 'en', target: 'de'),
        '[en-de] Hello',
      );
    });

    test('pivots through English', () async {
      await translator.downloadLanguage('de');
      await translator.downloadLanguage('es');
      expect(
        await translator.translate('Hola', source: 'es', target: 'de'),
        '[es-en|en-de] Hola',
      );
    });

    test('lists the languages whose models are missing', () async {
      await expectLater(
        translator.translate('Hola', source: 'es', target: 'de'),
        throwsA(
          isA<OfflineModelMissingException>().having(
            (e) => e.languages,
            'languages',
            ['es', 'de'],
          ),
        ),
      );
      await expectLater(
        translator.translate('Dobar dan', source: 'hr', target: 'de'),
        throwsA(
          isA<OfflineModelMissingException>().having(
            (e) => e.languages,
            'languages',
            ['hr', 'de'],
          ),
        ),
      );
      verifyNever(
        () => engine.translate(any(), any(), html: any(named: 'html')),
      );
      expect(server.requests, isEmpty);
    });

    test('unsupported languages throw', () async {
      await expectLater(
        translator.translate('x', source: 'en', target: 'fr'),
        throwsA(
          isA<OfflineLanguageUnsupportedException>().having(
            (e) => e.language,
            'language',
            'fr',
          ),
        ),
      );
      await expectLater(
        translator.translate('x', source: 'az', target: 'de'),
        throwsA(isA<OfflineLanguageUnsupportedException>()),
      );
    });

    test('blank text and the same language are returned as is', () async {
      expect(
        await translator.translate('  ', source: 'en', target: 'de'),
        '  ',
      );
      expect(
        await translator.translate('Hallo', source: 'de', target: 'de-AT'),
        'Hallo',
      );
    });

    test('identifies an auto source', () async {
      await translator.downloadLanguage('de');
      // The heuristic answers (no native identifier in these tests).
      expect(
        await translator.translate(
          'Ich weiß nicht, ob das eine gute Idee ist.',
          source: 'auto',
          target: 'en',
        ),
        startsWith('[de-en]'),
      );
      await expectLater(
        translator.translate('OK', source: '', target: 'de'),
        throwsA(isA<OfflineLanguageUnsupportedException>()),
      );
    });

    test('identifies a short auto source with CLD2', () async {
      await translator.downloadLanguage('es');
      languageId.detection = _detection('un', guess: 'es');
      expect(
        await translator.translate('Gracias', source: 'auto', target: 'en'),
        '[es-en] Gracias',
      );
    });

    test('translates long text piece by piece, keeping layout', () async {
      final short = create(chunk: 30);
      await short.downloadLanguage('de');
      const text = '  First paragraph here.\n\nSecond one is here.\n\n  ';
      final result = await short.translate(text, source: 'en', target: 'de');
      expect(
        result,
        '  [en-de] First paragraph here.\n\n[en-de] Second one is here.\n\n  ',
      );
      verify(() => engine.translate(any(), any(), html: any(named: 'html')))
          .called(2);
    });

    test('engine errors surface', () async {
      await translator.downloadLanguage('de');
      when(() => engine.translate(any(), any(), html: any(named: 'html')))
          .thenThrow(const BergamotEngineException('boom'));
      await expectLater(
        translator.translate('Hello', source: 'en', target: 'de'),
        throwsA(
          isA<BergamotEngineException>().having(
            (e) => e.toString(),
            'toString',
            'BergamotEngineException(boom)',
          ),
        ),
      );
    });
  });

  group('outdatedModels', () {
    test('lists installed models with a newer catalog version', () async {
      await translator.downloadLanguage('de');
      final newer = FakeModel('en', 'de', version: 'run2', seed: 9);
      final updated = BergamotTranslator(
        catalog: catalogOf([newer, models[1]]),
        root: root,
        engine: engine,
        isAvailable: true,
        isMeteredConnection: () async => false,
      );
      expect((await updated.outdatedModels()).map((m) => m.version), ['run2']);
      expect(await translator.outdatedModels(), isEmpty);
    });
  });

  group('identifyLanguage', () {
    test('is null for blank text, without asking CLD2', () async {
      expect(await translator.identifyLanguage(''), isNull);
      expect(await translator.identifyLanguage(' \n'), isNull);
      expect(languageId.texts, isEmpty);
    });

    test('decides with CLD2 where the engine runs', () async {
      languageId.detection = _detection('de');
      expect(await translator.identifyLanguage('Guten Morgen'), 'de');
      expect(languageId.texts, ['Guten Morgen']);

      // A strong guess counts for languages the engine translates from...
      languageId.detection = _detection('un', guess: 'es');
      expect(await translator.identifyLanguage('Gracias'), 'es');
      // ...not for others ("Sí" is guessed Irish).
      languageId.detection = _detection('un', guess: 'ga');
      expect(await translator.identifyLanguage('Sí'), isNull);
      // CLD2's reliable answer counts for every language.
      languageId.detection = _detection('sw');
      expect(await translator.identifyLanguage('Habari ya asubuhi'), 'sw');
    });

    test('falls back to the heuristic without CLD2', () async {
      // No native identifier (null), or a failing one.
      expect(await translator.identifyLanguage('안녕하세요'), 'ko');
      languageId.error = const BergamotEngineException('boom');
      expect(await translator.identifyLanguage('안녕하세요'), 'ko');
      expect(await translator.identifyLanguage('Danke'), isNull);
      expect(languageId.texts, hasLength(3));
    });

    test('uses only the heuristic where the engine cannot run', () async {
      languageId.detection = _detection('de');
      final unavailable = create(isAvailable: false);
      expect(await unavailable.identifyLanguage('안녕하세요'), 'ko');
      expect(await unavailable.identifyLanguage('Guten Morgen'), isNull);
      expect(languageId.texts, isEmpty);
    });

    test(
      'looks at the first 4096 characters, keeping surrogate pairs',
      () async {
        languageId.detection = _detection('en');
        final long = 'a' * 5000;
        expect(await translator.identifyLanguage(long), 'en');
        expect(
          languageId.texts.single,
          hasLength(BergamotTranslator.identificationSampleLength),
        );
        // An emoji (two code units) across the cut is left out whole.
        final emoji = '${'a' * 4095}\u{1F600}${'b' * 10}';
        await translator.identifyLanguage(emoji);
        expect(languageId.texts.last, 'a' * 4095);
        final short = 'a' * 4096;
        await translator.identifyLanguage(short);
        expect(languageId.texts.last, short);
      },
    );
  });

  test('dispose stops the engine', () async {
    await translator.dispose();
    verify(() => engine.dispose()).called(1);
  });
}
