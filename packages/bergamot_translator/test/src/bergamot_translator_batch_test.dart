import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_models.dart';

/// A [BergamotBatchEngine] answering `<text>` for every text, with one
/// sentence over the whole text when details are asked for.
class _BatchEngine implements BergamotBatchEngine {
  final batches = <({List<String> chain, List<String> texts, bool details})>[];
  final aborts = <Future<void>?>[];
  final preloaded = <List<String>>[];
  int trims = 0;

  /// Runs as batch `index` arrives.
  void Function(int index)? onBatch;

  /// Spaces the answers start with (the translator trims them).
  String padding = '';

  /// The score and word count of each text's sentence.
  ({double? score, int words}) Function(String text) quality = (_) =>
      (score: -0.1, words: 3);

  Exception? error;

  @override
  Future<List<OfflineTranslation>> translateBatch(
    List<ModelPaths> chain,
    List<String> texts, {
    bool html = false,
    bool details = false,
    Future<void>? abort,
  }) async {
    batches.add((chain: _keys(chain), texts: texts, details: details));
    aborts.add(abort);
    onBatch?.call(batches.length - 1);
    await Future<void>.delayed(Duration.zero);
    if (error case final error?) throw error;
    return [
      for (final text in texts)
        OfflineTranslation(
          text: '$padding<$text>',
          sentences: [
            if (details)
              OfflineSentence(
                sourceStart: 0,
                sourceEnd: text.length,
                targetStart: padding.length + 1,
                targetEnd: padding.length + 1 + text.length,
                score: quality(text).score,
                words: [
                  for (var i = 0; i < quality(text).words; i++)
                    OfflineWord(
                      targetStart: padding.length + 1,
                      targetEnd: padding.length + 2,
                      sourceStart: 0,
                      sourceEnd: 1,
                      alignment: 0.9,
                    ),
                ],
              ),
          ],
        ),
    ];
  }

  @override
  Future<void> preload(List<ModelPaths> chain) async =>
      preloaded.add(_keys(chain));

  @override
  Future<void> trim() async => trims++;

  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) => throw UnimplementedError('batches only');

  @override
  Future<void> release(String key) async {}

  @override
  Future<void> dispose() async {}

  static List<String> _keys(List<ModelPaths> chain) => [
    for (final paths in chain) paths.key.split('/').first,
  ];
}

/// No CLD2 here: the heuristic identifies.
class _NoLanguageId implements NativeLanguageIdentifier {
  @override
  Future<Cld2Detection?> identify(
    String text, {
    List<String> hints = const [],
  }) async => null;
}

/// A plain [BergamotEngine] (no batches).
class _PlainEngine implements BergamotEngine {
  final texts = <String>[];

  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) async {
    texts.add(text);
    return '[$text]';
  }

  @override
  Future<void> release(String key) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory root;
  late List<FakeModel> models;
  late FakeModelServer server;
  late _BatchEngine engine;

  BergamotTranslator create({
    BergamotEngine? using,
    bool isAvailable = true,
    int chunk = 2000,
    int batch = 6000,
  }) => BergamotTranslator(
    catalog: catalogOf(models),
    root: root,
    httpClient: server.client,
    engine: using ?? engine,
    languageId: _NoLanguageId(),
    isAvailable: isAvailable,
    isMeteredConnection: () async => false,
    maxChunkLength: chunk,
    maxBatchLength: batch,
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('bergamot_batch_');
    models = [
      FakeModel('en', 'de'),
      FakeModel('de', 'en'),
      FakeModel('es', 'en'),
      FakeModel('en', 'es'),
    ];
    server = FakeModelServer(models);
    engine = _BatchEngine();
    final installer = create();
    await installer.downloadLanguage('de');
    await installer.downloadLanguage('es');
  });

  tearDown(() => root.deleteSync(recursive: true));

  const layout = '  First paragraph here.\n\nSecond one is here.\n\n  ';

  group('translate with a batch engine', () {
    test('sends every piece of typed text in one call', () async {
      final translator = create(chunk: 30);

      final result = await translator.translate(
        layout,
        source: 'en',
        target: 'de',
      );

      expect(
        result,
        '  <First paragraph here.>\n\n<Second one is here.>\n\n  ',
      );
      expect(engine.batches, hasLength(1));
      expect(engine.batches.single.chain, ['en-de']);
      expect(engine.batches.single.texts, [
        'First paragraph here.',
        'Second one is here.',
      ]);
      expect(engine.batches.single.details, isFalse);
    });

    test('splits long text into batches of maxBatchLength', () async {
      final translator = create(chunk: 30, batch: 60);
      final text = [for (var i = 0; i < 5; i++) 'Paragraph number $i is here.']
          .join('\n\n');

      final result = await translator.translate(
        text,
        source: 'es',
        target: 'de',
      );

      expect(result, contains('<Paragraph number 4 is here.>'));
      expect(engine.batches, hasLength(3));
      for (final batch in engine.batches) {
        expect(batch.chain, ['es-en', 'en-de']);
        expect(batch.texts.join().length, lessThanOrEqualTo(60));
      }
      expect(engine.batches.expand((batch) => batch.texts), hasLength(5));
    });

    test('keeps pieces of whitespace as they are', () async {
      final text = 'A.\n\n${'\n' * 60}B.';

      final result = await create(
        chunk: 30,
      ).translateDetailed(text, source: 'en', target: 'de');

      expect(result.text, '<A.>\n\n${'\n' * 60}<B.>');
      expect(result.sentences.last.sourceIn(text), 'B.');
      expect(result.sentences.last.targetIn(result.text), 'B.');
    });

    test('blank text and the same language need no engine', () async {
      final translator = create();

      expect(
        await translator.translateDetailed(' ', source: 'en', target: 'de'),
        const OfflineTranslation(text: ' '),
      );
      expect(
        await translator.translateDetailed('Hallo', source: 'de', target: 'de'),
        const OfflineTranslation(text: 'Hallo'),
      );
      expect(engine.batches, isEmpty);
    });

    test('engine errors surface', () async {
      engine.error = const BergamotEngineException('boom');

      await expectLater(
        create().translate('Hello', source: 'en', target: 'de'),
        throwsA(isA<BergamotEngineException>()),
      );
    });
  });

  group('translateDetailed', () {
    test('places every sentence in the whole text', () async {
      engine.padding = '  ';
      final translator = create(chunk: 30);

      final result = await translator.translateDetailed(
        layout,
        source: 'en',
        target: 'de',
      );

      expect(
        result.text,
        '  <First paragraph here.>\n\n<Second one is here.>\n\n  ',
      );
      expect(engine.batches.single.details, isTrue);
      expect(
        [for (final s in result.sentences) s.sourceIn(layout)],
        ['First paragraph here.', 'Second one is here.'],
      );
      expect(
        [for (final s in result.sentences) s.targetIn(result.text)],
        ['First paragraph here.', 'Second one is here.'],
      );
      final second = result.sentences[1];
      expect(second.words.first.targetStart, second.targetStart);
      expect(second.words.first.sourceStart, second.sourceStart);
      expect(result.hasLowConfidence, isFalse);
    });

    test('flags unsure sentences of a few words', () async {
      engine.quality = (text) => switch (text) {
        'Unsure long one.' => (score: -0.8, words: 3),
        'Unsure.' => (score: -0.8, words: 2),
        'No score.' => (score: null, words: 5),
        _ => (score: -0.3, words: 4),
      };
      final translator = create(chunk: 18);

      final result = await translator.translateDetailed(
        'Unsure long one.\n\nUnsure.\n\nNo score.\n\nSure enough.',
        source: 'en',
        target: 'de',
      );

      expect(
        [for (final s in result.sentences) s.isLowConfidence],
        [true, false, false, false],
      );
      expect(result.hasLowConfidence, isTrue);
      expect(result.lowConfidenceSentences.single.score, -0.8);
    });

    test('has no sentences with an engine without batches', () async {
      final plain = _PlainEngine();
      final translator = create(using: plain, chunk: 30);

      final result = await translator.translateDetailed(
        layout,
        source: 'en',
        target: 'de',
      );

      expect(
        result,
        const OfflineTranslation(
          text: '  [First paragraph here.]\n\n[Second one is here.]\n\n  ',
        ),
      );
      expect(plain.texts, ['First paragraph here.', 'Second one is here.']);
    });
  });

  group('abort', () {
    test('an aborted request never reaches the engine', () async {
      await expectLater(
        create().translate(
          'Hello',
          source: 'en',
          target: 'de',
          abort: Future.value(),
        ),
        throwsA(isA<OfflineTranslationCancelledException>()),
      );
      expect(engine.batches, isEmpty);
    });

    test('stops between batches and passes abort on', () async {
      final abort = Completer<void>();
      engine.onBatch = (_) => abort.complete();
      final translator = create(chunk: 30, batch: 30);

      await expectLater(
        translator.translateDetailed(
          layout,
          source: 'en',
          target: 'de',
          abort: abort.future,
        ),
        throwsA(
          isA<OfflineTranslationCancelledException>().having(
            (e) => '$e',
            'toString',
            'OfflineTranslationCancelledException()',
          ),
        ),
      );
      expect(engine.batches, hasLength(1));
      expect(engine.aborts.single, same(abort.future));
    });

    test('an abort that fails counts as one', () async {
      final abort = Completer<void>();
      engine.onBatch = (_) => abort.completeError(StateError('gone'));

      await expectLater(
        create(
          chunk: 30,
          batch: 30,
        ).translate(layout, source: 'en', target: 'de', abort: abort.future),
        throwsA(isA<OfflineTranslationCancelledException>()),
      );
    });

    test('stops between pieces with an engine without batches', () async {
      final plain = _PlainEngine();
      final abort = Completer<void>();

      final translation = create(
        using: plain,
        chunk: 30,
      ).translate(layout, source: 'en', target: 'de', abort: abort.future);
      abort.complete();

      await expectLater(
        translation,
        throwsA(isA<OfflineTranslationCancelledException>()),
      );
      expect(plain.texts.length, lessThan(2));
    });
  });

  group('preload', () {
    test('loads the installed chain', () async {
      final translator = create();

      expect(await translator.preload(source: 'en', target: 'de'), isTrue);
      expect(await translator.preload(source: 'es', target: 'de'), isTrue);
      expect(engine.preloaded, [
        ['en-de'],
        ['es-en', 'en-de'],
      ]);
    });

    test('does nothing when it cannot', () async {
      final translator = create();

      expect(await translator.preload(source: 'auto', target: 'de'), isFalse);
      expect(await translator.preload(source: 'de', target: 'de'), isFalse);
      expect(await translator.preload(source: 'en', target: 'fr'), isFalse);
      root
        ..deleteSync(recursive: true)
        ..createSync();
      expect(await translator.preload(source: 'en', target: 'de'), isFalse);
      expect(
        await create(isAvailable: false).preload(source: 'en', target: 'de'),
        isFalse,
      );
      expect(
        await create(using: _PlainEngine()).preload(source: 'en', target: 'de'),
        isFalse,
      );
      expect(engine.preloaded, isEmpty);
    });
  });

  test('trimMemory trims a batch engine and skips others', () async {
    await create().trimMemory();
    await create(using: _PlainEngine()).trimMemory();

    expect(engine.trims, 1);
  });
}
