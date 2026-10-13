import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

/// Records calls; [playGate] lets tests hold playback start.
class _FakeAudioOutput implements AudioOutput {
  final List<Uint8List> played = [];
  final StreamController<void> completions = StreamController.broadcast();
  int stops = 0;
  bool disposed = false;
  Error? playError;
  Completer<void>? playGate;

  void complete() => completions.add(null);

  @override
  Stream<void> get onComplete => completions.stream;

  @override
  Future<void> play(Uint8List bytes) async {
    if (playGate case final gate?) await gate.future;
    if (playError case final error?) throw error;
    played.add(bytes);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await completions.close();
  }
}

Uint8List _clip(int value) => Uint8List.fromList([value]);

void main() {
  late TranslationRepository repository;
  late _FakeAudioOutput output;
  late SpeechService service;
  late List<String?> emitted;
  late StreamSubscription<String?> subscription;

  void stubTts({required Object answer, String? text, String? languageCode}) {
    when(
      () => repository.textToSpeech(
        text: text ?? any(named: 'text'),
        languageCode: languageCode ?? any(named: 'languageCode'),
      ),
    ).thenAnswer((invocation) async {
      final result = answer is Future<Uint8List> Function()
          ? await answer()
          : answer;
      if (result is Error) throw result;
      return result as Uint8List;
    });
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    repository = _MockTranslationRepository();
    output = _FakeAudioOutput();
    service = SpeechService(repository: repository, output: output);
    emitted = [];
    subscription = service.speaking.listen(emitted.add);
    stubTts(answer: _clip(1));
  });

  tearDown(() async {
    await subscription.cancel();
  });

  group(SpeechService, () {
    test('can be created with the default audio output', () async {
      final service = SpeechService(repository: repository);

      expect(service.current, isNull);
      await service.dispose();
    });

    test('is idle initially', () {
      expect(service.current, isNull);
    });

    test('fetches and plays the clip, reporting the id', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
      await flush();

      expect(output.played, [_clip(1)]);
      expect(service.current, 'target');
      expect(emitted, ['target']);
      verify(() => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'))
          .called(1);
    });

    test('trims the text before fetching', () async {
      await service.toggle(id: 'source', text: '  Hi \n', languageCode: 'en');

      verify(() => repository.textToSpeech(text: 'Hi', languageCode: 'en'))
          .called(1);
    });

    test('becomes idle when the clip completes', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

      output.complete();
      await flush();

      expect(service.current, isNull);
      expect(emitted, ['target', null]);
    });

    test('ignores completions while idle', () async {
      output.complete();
      await flush();

      expect(emitted, isEmpty);
    });

    test('toggling the playing id stops playback', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
      await flush();

      expect(output.stops, 1);
      expect(service.current, isNull);
      expect(emitted, ['target', null]);
      expect(output.played, hasLength(1));
    });

    test('toggling another id switches playback', () async {
      stubTts(text: 'Hello', answer: _clip(2));
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

      await service.toggle(id: 'source', text: 'Hello', languageCode: 'en');
      await flush();

      expect(output.stops, 1);
      expect(output.played, [_clip(1), _clip(2)]);
      expect(service.current, 'source');
      expect(emitted, ['target', 'source']);
    });

    test('empty text only stops playback', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

      await service.toggle(id: 'source', text: '   ', languageCode: 'en');
      await flush();

      expect(service.current, isNull);
      expect(emitted, ['target', null]);
      verifyNever(
        () => repository.textToSpeech(
          text: '',
          languageCode: any(named: 'languageCode'),
        ),
      );
    });

    group('cache', () {
      test('reuses clips for the same language and text', () async {
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'en');
        await service.stop();
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'en');

        verify(() => repository.textToSpeech(text: 'Hi', languageCode: 'en'))
            .called(1);
        expect(output.played, hasLength(2));
      });

      test('keys clips by language as well', () async {
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'en');
        await service.stop();
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'de');

        verify(
          () => repository.textToSpeech(
            text: 'Hi',
            languageCode: any(named: 'languageCode'),
          ),
        ).called(2);
      });

      test('evicts the least recently used clip beyond 20', () async {
        Future<void> say(int i) async {
          await service.toggle(id: 'a', text: 'text $i', languageCode: 'en');
          await service.stop();
        }

        for (var i = 0; i < SpeechService.cacheSize; i++) {
          await say(i);
        }
        await say(0); // Refreshes clip 0.
        await say(SpeechService.cacheSize); // Evicts clip 1.
        clearInteractions(repository);

        await say(0);
        verifyNever(
          () => repository.textToSpeech(
            text: 'text 0',
            languageCode: any(named: 'languageCode'),
          ),
        );

        await say(1);
        verify(
          () => repository.textToSpeech(text: 'text 1', languageCode: 'en'),
        ).called(1);
      });
    });

    group('failures', () {
      test('rethrows fetch errors and becomes idle', () async {
        stubTts(answer: StateError('offline'));

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsStateError,
        );
        await flush();

        expect(service.current, isNull);
        expect(emitted, ['target', null]);
        expect(output.played, isEmpty);
      });

      test('rejects empty audio without caching it', () async {
        stubTts(answer: Uint8List(0));

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsFormatException,
        );
        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsFormatException,
        );

        verify(
          () => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'),
        ).called(2);
      });

      test('rethrows playback errors and becomes idle', () async {
        output.playError = StateError('codec');

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsStateError,
        );

        expect(service.current, isNull);
      });
    });

    group('races', () {
      test('does not play a clip fetched after stop', () async {
        final fetch = Completer<Uint8List>();
        stubTts(answer: () => fetch.future);

        final toggle = service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
        );
        await service.stop();
        fetch.complete(_clip(1));
        await toggle;

        expect(output.played, isEmpty);
        expect(service.current, isNull);
      });

      test('swallows fetch errors of a superseded request', () async {
        final fetch = Completer<Uint8List>();
        stubTts(text: 'Bonjour', answer: () => fetch.future);
        stubTts(text: 'Hello', answer: _clip(2));

        final first = service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
        );
        await service.toggle(id: 'source', text: 'Hello', languageCode: 'en');
        fetch.completeError(StateError('offline'));
        await first;

        expect(service.current, 'source');
        expect(output.played, [_clip(2)]);
      });

      test('stops a clip whose playback started after stop', () async {
        output.playGate = Completer<void>();

        final toggle = service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
        );
        await flush();
        await service.stop();
        output.playGate!.complete();
        await toggle;

        expect(output.stops, 2);
        expect(service.current, isNull);
      });

      test('keeps a newer clip when an older one starts late', () async {
        output.playGate = Completer<void>();
        stubTts(text: 'Hello', answer: _clip(2));

        final first = service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
        );
        await flush();
        final second = service.toggle(
          id: 'source',
          text: 'Hello',
          languageCode: 'en',
        );
        output.playGate!.complete();
        await Future.wait([first, second]);

        expect(output.stops, 1);
        expect(service.current, 'source');
      });

      test('ignores the completion of a replaced clip', () async {
        final fetch = Completer<Uint8List>();
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
        stubTts(text: 'Hello', answer: () => fetch.future);

        final second = service.toggle(
          id: 'source',
          text: 'Hello',
          languageCode: 'en',
        );
        output.complete();
        await flush();

        expect(service.current, 'source');
        fetch.complete(_clip(2));
        await second;
        expect(service.current, 'source');
      });
    });

    test('dispose releases the output and closes the stream', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
      final done = expectLater(service.speaking, emitsDone);

      await service.dispose();

      await done;
      expect(output.disposed, isTrue);
      expect(service.current, isNull);
      expect(output.completions.hasListener, isFalse);
    });
  });
}
