import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bergamot_translator/src/engine/engine_factory_stub.dart'
    as stub;
import 'package:bergamot_translator/src/engine/ffi/isolate_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/native_library.dart';

void main() {
  const missing = ModelPaths(
    key: 'en-de/none',
    model: '/nonexistent/model.bin',
    shortlist: '/nonexistent/lex.bin',
    sourceVocab: '/nonexistent/vocab.spm',
  );

  group('IsolateBergamotEngine', () {
    test('reports a library that cannot be loaded, and retries', () async {
      final engine = IsolateBergamotEngine(
        libraryPath: '/nonexistent/libmozhi_bergamot.so',
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          engine.translate(const [missing], 'Hello'),
          throwsA(
            isA<BergamotEngineException>().having(
              (e) => e.message,
              'message',
              contains('Cannot load the native engine'),
            ),
          ),
        );
      }
      await engine.release('x');
      await engine.dispose();
    });

    test('release and dispose before the first call do nothing', () async {
      final engine = IsolateBergamotEngine();
      await engine.release('x');
      await engine.dispose();
    });

    test(
      'reports engine errors from the isolate and can be restarted',
      () async {
        final engine = IsolateBergamotEngine(libraryPath: nativeLibraryPath());
        addTearDown(engine.dispose);
        await expectLater(
          engine.translate(const [missing], 'Hello'),
          throwsA(
            isA<BergamotEngineException>().having(
              (e) => e.message,
              'message',
              allOf(contains('load en-de/none'), contains('No such file')),
            ),
          ),
        );
        await expectLater(
          engine.translate(const [], 'Hello'),
          throwsA(isA<BergamotEngineException>()),
        );
        await engine.release('en-de/none');
        await engine.dispose();
        // A new isolate starts on the next call.
        await expectLater(
          engine.translate(const [missing, missing, missing], 'x'),
          throwsA(isA<BergamotEngineException>()),
        );
      },
      skip: nativeLibrarySkip(),
    );
  });

  group('IsolateBergamotEngine batches', () {
    test('report engine errors and load like translate', () async {
      final engine = IsolateBergamotEngine(libraryPath: nativeLibraryPath());
      addTearDown(engine.dispose);

      await expectLater(
        engine.translateBatch(const [missing], ['Hello', 'World']),
        throwsA(
          isA<BergamotEngineException>().having(
            (e) => e.message,
            'message',
            contains('load en-de/none'),
          ),
        ),
      );
      await expectLater(
        engine.translateBatch(const [], ['x'], details: true),
        throwsA(isA<BergamotEngineException>()),
      );
      await expectLater(
        engine.preload(const [missing]),
        throwsA(isA<BergamotEngineException>()),
      );
      await engine.trim();
    }, skip: nativeLibrarySkip());

    test('an aborted request fails at once and the queue goes on', () async {
      final engine = IsolateBergamotEngine(libraryPath: nativeLibraryPath());
      addTearDown(engine.dispose);
      final abort = Completer<void>();

      final first = engine.translateBatch(const [missing], ['a']);
      final second = engine.translateBatch(
        const [missing],
        ['b'],
        abort: abort.future,
      );
      final third = engine.translateBatch(const [missing], ['c']);
      abort.complete();

      await Future.wait([
        expectLater(
          second,
          throwsA(isA<OfflineTranslationCancelledException>()),
        ),
        expectLater(first, throwsA(isA<BergamotEngineException>())),
        expectLater(third, throwsA(isA<BergamotEngineException>())),
      ]);
      // Already aborted: never sent.
      await expectLater(
        engine.translateBatch(const [missing], ['d'], abort: Future.value()),
        throwsA(isA<OfflineTranslationCancelledException>()),
      );
    }, skip: nativeLibrarySkip());

    test('trim before the first call does nothing', () async {
      final engine = IsolateBergamotEngine();
      await engine.trim();
      await engine.dispose();
    });

    test('pending requests fail when the isolate is stopped', () async {
      final engine = IsolateBergamotEngine(libraryPath: nativeLibraryPath());
      final first = expectLater(
        engine.translateBatch(const [missing], ['a']),
        throwsA(isA<BergamotEngineException>()),
      );
      final aborted = Completer<void>();
      final second = expectLater(
        engine.translateBatch(const [missing], ['b'], abort: aborted.future),
        throwsA(isA<Exception>()),
      );
      await engine.dispose();
      aborted.complete();

      await Future.wait([first, second]);
    }, skip: nativeLibrarySkip());
  });

  group('createBergamotEngine', () {
    test('creates the isolate engine where dart:ffi exists', () async {
      final engine = createBergamotEngine(libraryPath: '/nonexistent.so');
      expect(engine, isA<IsolateBergamotEngine>());
      await engine.dispose();
      expect(bergamotPlatformSupported, Platform.isAndroid);
    });
  });

  group('web stub', () {
    test('is unsupported', () async {
      final engine = stub.createBergamotEngine();
      expect(stub.bergamotPlatformSupported, isFalse);
      expect(
        () => engine.translate(const [missing], 'x'),
        throwsUnsupportedError,
      );
      expect(engine, isA<BergamotBatchEngine>());
      final batches = engine as BergamotBatchEngine;
      expect(
        () => batches.translateBatch(const [missing], ['x']),
        throwsUnsupportedError,
      );
      await batches.preload(const [missing]);
      await batches.trim();
      await engine.release('x');
      await engine.dispose();
    });
  });
}
