import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/fake_models.dart';

class _MockEngine extends Mock implements WhisperEngine;

void main() {
  late Directory root;
  late Uint8List tinyBytes;
  late Uint8List baseBytes;
  late WhisperCatalogModel tiny;
  late WhisperCatalogModel base;
  late _MockEngine engine;
  late WhisperSpeech speech;

  setUpAll(() => registerFallbackValue(Float32List(0)));

  setUp(() {
    root = Directory.systemTemp.createTempSync('whisper_speech_');
    tinyBytes = fakeModelBytes(300);
    baseBytes = fakeModelBytes(600, seed: 3);
    tiny = fakeModel('tiny', tinyBytes);
    base = fakeModel('base', baseBytes);
    engine = _MockEngine();
    when(
      () => engine.transcribe(
        any(),
        any(),
        language: any(named: 'language'),
        threads: any(named: 'threads'),
      ),
    ).thenAnswer((_) async => const WhisperTranscription('hi', language: 'en'));
    when(() => engine.cancel()).thenAnswer((_) async {});
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    speech = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [tiny, base]),
      root: root,
      httpClient: MockClient((request) async {
        final bytes = request.url.path.endsWith('tiny.bin')
            ? tinyBytes
            : baseBytes;
        return http.Response.bytes(bytes, 200);
      }),
      engine: engine,
      isAvailable: true,
    );
  });

  tearDown(() async {
    await speech.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> import(WhisperCatalogModel model, Uint8List bytes) async {
    final file = File(p.join(root.path, model.name))..writeAsBytesSync(bytes);
    final result = await speech.importFiles([file]);
    expect(result.installed, [model]);
  }

  test('defaults follow the platform (no engine on the test host)', () {
    final created = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [tiny]),
      root: root,
    );
    expect(created.isAvailable, isFalse);
    expect(created.models.root, root);
    created.models.close();
  });

  test('without a model nothing is ready', () async {
    expect(await speech.installedModels(), isEmpty);
    expect(await speech.isReady(), isFalse);
    expect(await speech.modelFor(), isNull);
    await expectLater(
      speech.transcribe(Float32List(16000)),
      throwsA(isA<WhisperModelMissingException>()),
    );
    expect(
      const WhisperModelMissingException().toString(),
      'WhisperModelMissingException()',
    );
  });

  test('downloads a model and transcribes with it', () async {
    final progress = <double>[];
    await speech.download(tiny, onProgress: (e) => progress.add(e.fraction));
    expect(progress.last, 1);
    expect(await speech.installedModels(), [tiny]);
    expect(await speech.isReady(), isTrue);

    final samples = Float32List(1600);
    final result = await speech.transcribe(samples, language: 'pt-BR');
    expect(result, const WhisperTranscription('hi', language: 'en'));
    final installed = await speech.modelFor();
    verify(() => engine.transcribe(installed!.path, samples, language: 'pt'))
        .called(1);
  });

  test('auto and unknown languages are detected', () async {
    await import(tiny, tinyBytes);
    await speech.transcribe(Float32List(1));
    await speech.transcribe(Float32List(1), language: 'yue');
    verify(() => engine.transcribe(any(), any())).called(2);
  });

  test('passes the thread count on', () async {
    await import(tiny, tinyBytes);
    await speech.transcribe(Float32List(1), threads: 2);
    verify(
      () => engine.transcribe(
        any(),
        any(),
        language: any(named: 'language'),
        threads: 2,
      ),
    ).called(1);
  });

  test('prefers the requested model, else the most accurate', () async {
    await import(tiny, tinyBytes);
    await import(base, baseBytes);
    expect(await speech.installedModels(), [tiny, base]);
    expect((await speech.modelFor())!.id, 'base');
    expect((await speech.modelFor(preferred: 'tiny'))!.id, 'tiny');
    expect((await speech.modelFor(preferred: 'large'))!.id, 'base');

    await speech.delete('base');
    expect((await speech.modelFor(preferred: 'base'))!.id, 'tiny');
  });

  test('ignores an installed file that is not the catalog file', () async {
    await import(tiny, tinyBytes);
    final changed = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [fakeModel('tiny', baseBytes)]),
      root: root,
      engine: engine,
      isAvailable: true,
    );
    expect(await changed.installedModels(), isEmpty);
    expect(await changed.modelFor(), isNull);
    changed.models.close();
  });

  test('delete releases the loaded model first', () async {
    await import(tiny, tinyBytes);
    final path = (await speech.modelFor())!.path;
    await speech.delete('tiny');
    verify(() => engine.release(path)).called(1);
    expect(await speech.installedModels(), isEmpty);

    // Nothing to release for a model that is not installed.
    await speech.delete('base');
    verifyNever(() => engine.release(any(that: isNot(path))));
  });

  test('cancel and dispose reach the engine', () async {
    await speech.cancel();
    verify(() => engine.cancel()).called(1);
    await speech.cleanUp();
    await speech.dispose();
    verify(() => engine.dispose()).called(1);
  });

  test('refuses to transcribe where the engine cannot run', () async {
    final unavailable = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [tiny]),
      root: root,
      engine: engine,
      isAvailable: false,
    );
    await import(tiny, tinyBytes);
    expect(await unavailable.isReady(), isFalse);
    await expectLater(
      unavailable.transcribe(Float32List(1)),
      throwsA(isA<WhisperEngineException>()),
    );
    unavailable.models.close();
  });

  group('memory', () {
    const idleTime = Duration(milliseconds: 300);
    const pastIdle = Duration(milliseconds: 450);
    late WhisperSpeech idle;

    setUp(
      () => idle = WhisperSpeech(
        catalog: WhisperModelCatalog(models: [tiny]),
        root: root,
        engine: engine,
        isAvailable: true,
        idleUnloadAfter: idleTime,
      ),
    );
    tearDown(() => idle.models.close());

    test('keeps the model loaded without idleUnloadAfter', () async {
      await import(tiny, tinyBytes);
      await speech.transcribe(Float32List(1));
      await Future<void>.delayed(pastIdle);

      verifyNever(() => engine.dispose());
    });

    test('unloads the model once idle for idleUnloadAfter', () async {
      await import(tiny, tinyBytes);
      await idle.transcribe(Float32List(1));
      verifyNever(() => engine.dispose());

      // A new transcription restarts the wait.
      await Future<void>.delayed(idleTime ~/ 3);
      await idle.transcribe(Float32List(1));
      await Future<void>.delayed(idleTime ~/ 3);
      verifyNever(() => engine.dispose());

      await Future<void>.delayed(pastIdle);
      verify(() => engine.dispose()).called(1);
    });

    test('a failed transcription counts as use too', () async {
      await import(tiny, tinyBytes);
      when(
        () => engine.transcribe(
          any(),
          any(),
          language: any(named: 'language'),
          threads: any(named: 'threads'),
        ),
      ).thenThrow(const WhisperCancelledException());

      await expectLater(
        idle.transcribe(Float32List(1)),
        throwsA(isA<WhisperCancelledException>()),
      );
      await Future<void>.delayed(pastIdle);
      verify(() => engine.dispose()).called(1);
    });

    test('unload stops the engine at once when nothing runs', () async {
      await import(tiny, tinyBytes);
      await idle.transcribe(Float32List(1));

      await idle.unload();
      verify(() => engine.dispose()).called(1);
      // The idle timer is gone.
      await Future<void>.delayed(pastIdle);
      verifyNever(() => engine.dispose());
    });

    test('unload waits for a running transcription', () async {
      await import(tiny, tinyBytes);
      final heard = Completer<WhisperTranscription>();
      final started = Completer<void>();
      when(
        () => engine.transcribe(
          any(),
          any(),
          language: any(named: 'language'),
          threads: any(named: 'threads'),
        ),
      ).thenAnswer((_) {
        started.complete();
        return heard.future;
      });

      final transcription = idle.transcribe(Float32List(1));
      await started.future;
      await idle.unload();
      verifyNever(() => engine.dispose());

      heard.complete(const WhisperTranscription('ok'));
      expect((await transcription).text, 'ok');
      await pumpEventQueue();
      verify(() => engine.dispose()).called(1);
      // Unloaded rather than waiting for the idle timeout.
      await Future<void>.delayed(pastIdle);
      verifyNever(() => engine.dispose());
    });

    test('dispose cancels the idle timer', () async {
      await import(tiny, tinyBytes);
      await idle.transcribe(Float32List(1));
      await idle.dispose();
      verify(() => engine.dispose()).called(1);

      await Future<void>.delayed(pastIdle);
      verifyNever(() => engine.dispose());
    });
  });
}
