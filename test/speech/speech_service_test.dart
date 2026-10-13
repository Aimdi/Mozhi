import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/speech/speech_chunker.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

class _MockKeyValueStore extends Mock implements KeyValueStore;

/// Records calls; [playGate] lets tests hold playback start.
class _FakeAudioOutput implements AudioOutput {
  final List<Uint8List> played = [];
  final List<double> rates = [];
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
  Future<void> setPlaybackRate(double rate) async => rates.add(rate);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await completions.close();
  }
}

/// Records calls; [gates] hold the named step (`available`, `language`,
/// `rate`, `speak`) until completed.
class _FakeDeviceTts implements DeviceTts {
  bool supported = true;
  Set<String> languages = {'fr', 'en', 'he'};
  final List<String> calls = [];
  final Map<String, Completer<void>> gates = {};
  final StreamController<void> completions = StreamController.broadcast();
  int stops = 0;
  bool disposed = false;
  Error? speakError;

  void complete() => completions.add(null);

  Future<void> _step(String name, String call) async {
    calls.add(call);
    if (gates[name] case final gate?) await gate.future;
  }

  @override
  bool get isSupported => supported;

  @override
  Future<bool> isLanguageAvailable(String languageTag) async {
    await _step('available', 'available $languageTag');
    return languages.contains(languageTag);
  }

  @override
  Future<void> setLanguage(String languageTag) =>
      _step('language', 'language $languageTag');

  @override
  Future<void> setSpeechRate({required bool slow}) =>
      _step('rate', slow ? 'rate slow' : 'rate normal');

  @override
  Future<void> speak(String text) async {
    await _step('speak', 'speak $text');
    if (speakError case final error?) throw error;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Stream<void> get onComplete => completions.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await completions.close();
  }
}

Uint8List _clip(int value) => Uint8List.fromList([value]);

const _instance = MozhiInstance(url: 'https://mozhi.example');

void main() {
  late TranslationRepository repository;
  late _FakeAudioOutput output;
  late _FakeDeviceTts device;
  late MemoryStore store;
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

  Matcher unavailable(String languageCode, {Object? cause}) =>
      isA<SpeechUnavailableException>()
          .having((e) => e.languageCode, 'languageCode', languageCode)
          .having((e) => e.cause, 'cause', cause ?? isNull);

  setUp(() {
    repository = _MockTranslationRepository();
    output = _FakeAudioOutput();
    device = _FakeDeviceTts();
    store = MemoryStore();
    service = SpeechService(
      repository: repository,
      output: output,
      deviceTts: device,
      store: store,
    );
    emitted = [];
    subscription = service.speaking.listen(emitted.add);
    when(() => repository.instances).thenReturn(const [_instance]);
    stubTts(answer: _clip(1));
  });

  tearDown(() async {
    await subscription.cancel();
  });

  group(SpeechService, () {
    test('can be created with the default outputs', () async {
      final service = SpeechService(repository: repository);

      expect(service.current, isNull);
      await service.dispose();
    });

    test('is idle initially', () {
      expect(service.current, isNull);
    });

    test('reports whether the device has a speech engine', () {
      expect(service.deviceVoiceSupported, isTrue);

      device.supported = false;

      expect(service.deviceVoiceSupported, isFalse);
    });

    group('with Mozhi', () {
      test('fetches and plays the clip, reporting the id', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
        await flush();

        expect(output.played, [_clip(1)]);
        expect(output.rates, [1]);
        expect(service.current, 'target');
        expect(emitted, ['target']);
        expect(device.calls, isEmpty);
        verify(
          () => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'),
        ).called(1);
      });

      test('plays slow clips at the slow playback rate', () async {
        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        );

        expect(output.rates, [SpeechService.slowPlaybackRate]);
        expect(output.played, [_clip(1)]);
      });

      test('trims the text before fetching', () async {
        await service.toggle(id: 'source', text: '  Hi \n', languageCode: 'en');

        verify(() => repository.textToSpeech(text: 'Hi', languageCode: 'en'))
            .called(1);
      });

      test('sends Mozhi its own language codes', () async {
        await service.toggle(id: 'target', text: 'Shalom', languageCode: 'iw');

        verify(
          () => repository.textToSpeech(text: 'Shalom', languageCode: 'iw'),
        ).called(1);
      });

      test('becomes idle when the clip completes', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        output.complete();
        await flush();

        expect(service.current, isNull);
        expect(emitted, ['target', null]);
      });

      test('ignores device completions while a clip plays', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        device.complete();
        await flush();

        expect(service.current, 'target');
      });
    });

    test('ignores completions while idle', () async {
      output.complete();
      device.complete();
      await flush();

      expect(emitted, isEmpty);
    });

    test('toggling the playing id stops playback', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
      await flush();

      expect(output.stops, 1);
      expect(device.stops, 1);
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

    group('device fallback', () {
      test('speaks on the device without Mozhi instances', () async {
        when(() => repository.instances).thenReturn(const []);

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls, [
          'available fr',
          'language fr',
          'rate normal',
          'speak Bonjour',
        ]);
        expect(service.current, 'target');
        expect(output.played, isEmpty);
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
      });

      test('uses the slow device rate', () async {
        when(() => repository.instances).thenReturn(const []);

        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        );

        expect(device.calls, contains('rate slow'));
      });

      test('passes the BCP-47 tag to the device', () async {
        when(() => repository.instances).thenReturn(const []);

        await service.toggle(id: 'target', text: 'Shalom', languageCode: 'iw');

        expect(device.calls.first, 'available he');
      });

      test('takes over when the Mozhi fetch fails', () async {
        stubTts(answer: StateError('offline'));

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls.last, 'speak Bonjour');
        expect(output.played, isEmpty);
        expect(service.current, 'target');
      });

      test('takes over when Mozhi playback fails', () async {
        output.playError = StateError('codec');

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls.last, 'speak Bonjour');
        expect(service.current, 'target');
      });

      test('skips Mozhi for codes it cannot speak', () async {
        await expectLater(
          service.toggle(id: 'target', text: 'Arr', languageCode: 'Pirate'),
          throwsA(unavailable('Pirate')),
        );

        expect(device.calls, isEmpty);
        expect(service.current, isNull);
      });

      test('honours a custom Mozhi language check', () async {
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          mozhiSupportsLanguage: (code) => code != 'fr',
        );

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls.last, 'speak Bonjour');
        expect(output.played, isEmpty);
      });

      test('skips the device when it has no speech engine', () async {
        device.supported = false;
        stubTts(answer: StateError('offline'));

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr', cause: isStateError)),
        );

        expect(device.calls, isEmpty);
      });

      test('becomes idle when the utterance completes', () async {
        when(() => repository.instances).thenReturn(const []);
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        output.complete();
        await flush();
        expect(service.current, 'target');

        device.complete();
        await flush();
        expect(service.current, isNull);
        expect(emitted, ['target', null]);
      });

      test('handles an utterance that ends before speak returns', () async {
        when(() => repository.instances).thenReturn(const []);
        device.gates['speak'] = Completer<void>();

        final toggle = service.toggle(
          id: 'target',
          text: 'Hi',
          languageCode: 'en',
        );
        await flush();
        device.complete();
        await flush();
        device.gates['speak']!.complete();
        await toggle;

        expect(service.current, isNull);
        expect(emitted, ['target', null]);
      });
    });

    group('failures', () {
      setUp(() => device.languages = {});

      test('throws SpeechUnavailableException with the Mozhi error', () async {
        stubTts(answer: StateError('offline'));

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr', cause: isStateError)),
        );
        await flush();

        expect(service.current, isNull);
        expect(emitted, ['target', null]);
        expect(output.played, isEmpty);
        expect(device.calls, ['available fr']);
      });

      test('throws without a cause when nothing could be tried', () async {
        when(() => repository.instances).thenReturn(const []);

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr')),
        );
      });

      test('rejects empty audio without caching it', () async {
        stubTts(answer: Uint8List(0));

        for (var i = 0; i < 2; i++) {
          await expectLater(
            service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
            throwsA(unavailable('fr', cause: isFormatException)),
          );
        }

        verify(
          () => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'),
        ).called(2);
      });

      test('reports playback errors and becomes idle', () async {
        output.playError = StateError('codec');

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr', cause: isStateError)),
        );

        expect(service.current, isNull);
      });

      test('reports device errors and ignores their completion', () async {
        when(() => repository.instances).thenReturn(const []);
        device
          ..languages = {'fr'}
          ..speakError = StateError('engine');

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr', cause: isStateError)),
        );
        device.complete();
        await flush();

        expect(emitted, ['target', null]);
      });

      test('rethrows when stopping the previous clip fails', () async {
        final service = SpeechService(
          repository: repository,
          output: _ThrowingStopOutput(),
          deviceTts: device,
        );
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'en');

        await expectLater(
          service.toggle(id: 'b', text: 'Hello', languageCode: 'en'),
          throwsStateError,
        );
        expect(service.current, isNull);
      });
    });

    group('preferDeviceVoice', () {
      test('is false until loaded', () async {
        await store.write(SpeechService.preferDeviceKey, 'true');

        expect(service.preferDeviceVoice, isFalse);
        expect(await service.loadPreferDeviceVoice(), isTrue);
        expect(service.preferDeviceVoice, isTrue);
      });

      test('reads the store once', () async {
        final store = _MockKeyValueStore();
        when(() => store.read(any())).thenAnswer((_) async => 'true');
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: store,
        );

        await service.loadPreferDeviceVoice();
        await service.loadPreferDeviceVoice();

        verify(() => store.read(SpeechService.preferDeviceKey)).called(1);
      });

      test('reads as false when the store fails or is missing', () async {
        final store = _MockKeyValueStore();
        when(() => store.read(any())).thenThrow(Exception('locked'));
        final failing = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: store,
        );
        final storeless = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
        );

        expect(await failing.loadPreferDeviceVoice(), isFalse);
        expect(await storeless.loadPreferDeviceVoice(), isFalse);
      });

      test('persists changes and applies them immediately', () async {
        await service.setPreferDeviceVoice(enabled: true);

        expect(service.preferDeviceVoice, isTrue);
        expect(await service.loadPreferDeviceVoice(), isTrue);
        expect(store.values[SpeechService.preferDeviceKey], 'true');

        await service.setPreferDeviceVoice(enabled: false);

        expect(store.values[SpeechService.preferDeviceKey], 'false');
      });

      test('keeps a change made while the stored value loads', () async {
        final read = Completer<String?>();
        final store = _MockKeyValueStore();
        when(() => store.read(any())).thenAnswer((_) => read.future);
        when(() => store.write(any(), any())).thenAnswer((_) async {});
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: store,
        );

        final loading = service.loadPreferDeviceVoice();
        await service.setPreferDeviceVoice(enabled: true);
        read.complete('false');

        expect(await loading, isTrue);
        expect(service.preferDeviceVoice, isTrue);
      });

      test('works without a store', () async {
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
        );

        await service.setPreferDeviceVoice(enabled: true);

        expect(service.preferDeviceVoice, isTrue);
      });

      test('tries the device first', () async {
        await service.setPreferDeviceVoice(enabled: true);

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls.last, 'speak Bonjour');
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
      });

      test('falls back to Mozhi without a device voice', () async {
        await store.write(SpeechService.preferDeviceKey, 'true');
        device.languages = {};

        await service.toggle(id: 'target', text: 'Hallo', languageCode: 'de');

        expect(device.calls, ['available de']);
        expect(output.played, [_clip(1)]);
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
        await flush();
        await service.stop();
        fetch.complete(_clip(1));
        await toggle;

        expect(output.played, isEmpty);
        expect(device.calls, isEmpty);
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
        await flush();
        await service.toggle(id: 'source', text: 'Hello', languageCode: 'en');
        fetch.completeError(StateError('offline'));
        await first;

        expect(service.current, 'source');
        expect(output.played, [_clip(2)]);
        expect(device.calls, isEmpty);
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
        await flush(); // The newer clip starts too.
        output.playGate!.complete();
        await Future.wait([first, second]);

        expect(output.stops, 1);
        expect(output.played, [_clip(1), _clip(2)]);
        expect(service.current, 'source');
      });

      test(
        'silences an older clip that starts while the newer one loads',
        () async {
          output.playGate = Completer<void>();
          final fetch = Completer<Uint8List>();
          stubTts(text: 'Hello', answer: () => fetch.future);

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
          await first;

          expect(output.stops, 2);
          expect(service.current, 'source');

          fetch.complete(_clip(2));
          await second;
          expect(output.played.last, _clip(2));
          expect(service.current, 'source');
        },
      );

      test(
        'stops a late clip when the newer request uses the device',
        () async {
          output.playGate = Completer<void>();
          await service.setPreferDeviceVoice(enabled: false);

          final first = service.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
          );
          await flush();
          when(() => repository.instances).thenReturn(const []);
          await service.toggle(id: 'source', text: 'Hello', languageCode: 'en');
          output.playGate!.complete();
          await first;

          expect(output.stops, 2);
          expect(device.calls.last, 'speak Hello');
          expect(service.current, 'source');
        },
      );

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

      group('on the device', () {
        setUp(() => when(() => repository.instances).thenReturn(const []));

        for (final (step, next) in [
          ('available', 'language fr'),
          ('language', 'rate normal'),
          ('rate', 'speak Bonjour'),
        ]) {
          test('stops before "$next" when stopped during "$step"', () async {
            device.gates[step] = Completer<void>();

            final toggle = service.toggle(
              id: 'target',
              text: 'Bonjour',
              languageCode: 'fr',
            );
            await flush();
            await service.stop();
            device.gates[step]!.complete();
            await toggle;

            expect(device.calls, isNot(contains(next)));
            expect(service.current, isNull);
          });
        }

        test(
          'stays silent when an unavailable check ends after stop',
          () async {
            device
              ..languages = {}
              ..gates['available'] = Completer<void>();

            final toggle = service.toggle(
              id: 'target',
              text: 'Bonjour',
              languageCode: 'fr',
            );
            await flush();
            await service.stop();
            device.gates['available']!.complete();
            await toggle;

            expect(service.current, isNull);
          },
        );

        test('stops an utterance that started after stop', () async {
          device.gates['speak'] = Completer<void>();

          final toggle = service.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
          );
          await flush();
          await service.stop();
          device.gates['speak']!.complete();
          await toggle;

          expect(device.stops, 2);
          expect(service.current, isNull);
        });

        test('keeps a newer utterance when an older one starts late', () async {
          device.gates['speak'] = Completer<void>();

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
          await flush();
          device.gates['speak']!.complete();
          await Future.wait([first, second]);

          expect(device.stops, 1);
          expect(service.current, 'source');
        });

        test('swallows errors of a superseded utterance', () async {
          final gate = device.gates['speak'] = Completer<void>();
          device.speakError = StateError('engine');

          final first = service.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
          );
          await flush();
          when(() => repository.instances).thenReturn(const [_instance]);
          stubTts(answer: _clip(2));
          await service.toggle(id: 'source', text: 'Hello', languageCode: 'en');
          gate.complete();
          await first;

          expect(service.current, 'source');
          expect(output.played, [_clip(2)]);
        });
      });
    });

    group('long text', () {
      // Three sentences of 124-164 characters: one Mozhi chunk each.
      final sentences = [
        for (final word in ['alpha', 'bravo', 'charlie'])
          '${'$word ' * 20}end.',
      ];
      final text = sentences.join(' ');

      Future<void> speak({bool slow = false}) => service.toggle(
        id: 'target',
        text: text,
        languageCode: 'en',
        slow: slow,
      );

      int fetches(int chunk) => verify(
        () => repository.textToSpeech(
          text: sentences[chunk],
          languageCode: any(named: 'languageCode'),
        ),
      ).callCount;

      setUp(() {
        for (var i = 0; i < sentences.length; i++) {
          stubTts(text: sentences[i], answer: _clip(i + 1));
        }
      });

      test('is split into one chunk per sentence', () {
        expect(splitTextForSpeech(text), sentences);
      });

      test('plays the chunks in order, fetching one ahead', () async {
        await speak();
        await flush();

        expect(output.played, [_clip(1)]);
        expect(fetches(0), 1);
        expect(fetches(1), 1);
        verifyNever(
          () => repository.textToSpeech(
            text: sentences[2],
            languageCode: any(named: 'languageCode'),
          ),
        );

        output.complete();
        await flush();

        expect(output.played, [_clip(1), _clip(2)]);
        expect(fetches(2), 1);
        expect(service.current, 'target');

        output.complete();
        await flush();

        expect(output.played, [_clip(1), _clip(2), _clip(3)]);
        expect(service.current, 'target');

        output.complete();
        await flush();

        expect(service.current, isNull);
        expect(emitted, ['target', null]);
        expect(output.rates, [1]);
        expect(output.stops, 0);
        expect(device.calls, isEmpty);
      });

      test('sets the slow rate once for all chunks', () async {
        await speak(slow: true);
        output.complete();
        await flush();

        expect(output.rates, [SpeechService.slowPlaybackRate]);
        expect(output.played, hasLength(2));
      });

      test('waits for a chunk that is still loading', () async {
        final fetch = Completer<Uint8List>();
        stubTts(text: sentences[1], answer: () => fetch.future);
        await speak();
        await flush();

        output
          ..complete()
          ..complete(); // A stray completion between chunks is ignored.
        await flush();

        expect(output.played, [_clip(1)]);
        expect(service.current, 'target');

        fetch.complete(_clip(2));
        await flush();

        expect(output.played, [_clip(1), _clip(2)]);
        expect(fetches(2), 1);
      });

      test('caches every chunk', () async {
        for (var round = 0; round < 2; round++) {
          await speak();
          for (var i = 0; i < sentences.length; i++) {
            output.complete();
            await flush();
          }
          expect(service.current, isNull);
        }

        expect(
          [for (var i = 0; i < sentences.length; i++) fetches(i)],
          [1, 1, 1],
        );
        expect(output.played, hasLength(6));
      });

      group('stopping', () {
        test('stop ends the sequence', () async {
          await speak();
          await flush();

          await service.stop();
          output.complete();
          await flush();

          expect(output.played, [_clip(1)]);
          expect(output.stops, 1);
          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('toggling the id mid-sequence stops it', () async {
          await speak();
          output.complete();
          await flush();

          await speak();
          output.complete();
          await flush();

          expect(output.played, [_clip(1), _clip(2)]);
          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('does not play a chunk that loads after stop', () async {
          final fetch = Completer<Uint8List>();
          stubTts(text: sentences[1], answer: () => fetch.future);
          await speak();
          output.complete();
          await flush();

          await service.stop();
          fetch.complete(_clip(2));
          await flush();

          expect(output.played, [_clip(1)]);
          expect(service.current, isNull);
        });

        test('stops a chunk whose playback started after stop', () async {
          await speak();
          output
            ..playGate = Completer<void>()
            ..complete();
          await flush();

          await service.stop();
          output.playGate!.complete();
          await flush();

          expect(output.stops, 2);
          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('switching to another id drops the rest', () async {
          stubTts(text: 'Hello', answer: _clip(9));
          await speak();
          await flush();

          await service.toggle(id: 'source', text: 'Hello', languageCode: 'en');
          output.complete();
          await flush();

          expect(output.played, [_clip(1), _clip(9)]);
          expect(service.current, isNull);
          expect(emitted, ['target', 'source', null]);
        });

        test('dispose drops the rest', () async {
          final fetch = Completer<Uint8List>();
          stubTts(text: sentences[1], answer: () => fetch.future);
          await speak();
          await flush();

          await service.dispose();
          fetch.completeError(StateError('offline'));
          await flush();

          expect(output.played, [_clip(1)]);
          expect(device.calls, isEmpty);
        });
      });

      group('device fallback', () {
        test('reads the whole text when the first chunk fails', () async {
          stubTts(text: sentences[0], answer: StateError('offline'));

          await speak();

          expect(device.calls.last, 'speak $text');
          expect(output.played, isEmpty);
          expect(service.current, 'target');
        });

        test('reads the whole text when a later chunk fails', () async {
          stubTts(text: sentences[1], answer: StateError('offline'));

          await speak();
          await flush();

          expect(output.played, [_clip(1)]);
          expect(output.stops, 1); // The first chunk is cut short.
          expect(device.calls, [
            'available en',
            'language en',
            'rate normal',
            'speak $text',
          ]);
          expect(service.current, 'target');

          output.complete();
          await flush();
          expect(service.current, 'target');

          device.complete();
          await flush();
          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('uses the slow device rate for slow text', () async {
          stubTts(text: sentences[1], answer: StateError('offline'));

          await speak(slow: true);
          await flush();

          expect(device.calls, contains('rate slow'));
        });

        test(
          'reads the whole text when a chunk fails between chunks',
          () async {
            final fetch = Completer<Uint8List>();
            stubTts(text: sentences[1], answer: () => fetch.future);
            await speak();
            output.complete();
            await flush();

            fetch.completeError(StateError('offline'));
            await flush();

            expect(output.stops, 0);
            expect(device.calls.where((c) => c.startsWith('speak')), [
              'speak $text',
            ]);
            expect(service.current, 'target');
          },
        );

        test('reads the whole text when a later chunk cannot play', () async {
          await speak();
          output
            ..playError = StateError('codec')
            ..complete();
          await flush();

          expect(output.played, [_clip(1)]);
          expect(device.calls.last, 'speak $text');
          expect(service.current, 'target');
        });

        test(
          'finishes the current chunk without a device voice, then stops',
          () async {
            device.languages = {};
            stubTts(text: sentences[1], answer: StateError('offline'));

            await speak();
            await flush();

            expect(output.stops, 0);
            expect(service.current, 'target');

            output.complete();
            await flush();

            expect(output.played, [_clip(1)]);
            expect(device.calls, everyElement('available en'));
            expect(service.current, isNull);
            expect(emitted, ['target', null]);
          },
        );

        test('becomes idle when the device fails to take over', () async {
          device.speakError = StateError('engine');
          stubTts(text: sentences[1], answer: StateError('offline'));

          await speak();
          await flush();

          expect(device.calls.last, 'speak $text');
          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('ignores a later chunk failing after stop', () async {
          final fetch = Completer<Uint8List>();
          stubTts(text: sentences[1], answer: () => fetch.future);
          await speak();
          await service.stop();

          fetch.completeError(StateError('offline'));
          await flush();

          expect(device.calls, isEmpty);
          expect(service.current, isNull);
        });

        test(
          'does not take over when stopped during the voice check',
          () async {
            final available = device.gates['available'] = Completer<void>();
            stubTts(text: sentences[1], answer: StateError('offline'));
            await speak();
            await flush();

            await service.stop();
            available.complete();
            await flush();

            expect(device.calls, ['available en']);
            expect(service.current, isNull);
          },
        );

        test(
          'takes over once when the chunk ends during the voice check',
          () async {
            final available = device.gates['available'] = Completer<void>();
            stubTts(text: sentences[1], answer: StateError('offline'));
            await speak();
            await flush();

            output.complete(); // Ends before the device answers.
            await flush();
            available.complete();
            await flush();

            expect(output.stops, 0);
            expect(device.calls.where((c) => c.startsWith('speak')), [
              'speak $text',
            ]);
            expect(service.current, 'target');
          },
        );
      });
    });

    test('dispose releases both outputs and closes the stream', () async {
      await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
      final done = expectLater(service.speaking, emitsDone);

      await service.dispose();

      await done;
      expect(output.disposed, isTrue);
      expect(device.disposed, isTrue);
      expect(service.current, isNull);
      expect(output.completions.hasListener, isFalse);
      expect(device.completions.hasListener, isFalse);
    });
  });

  group(SpeechUnavailableException, () {
    test('describes the language and cause', () {
      expect(
        const SpeechUnavailableException('fr').toString(),
        'SpeechUnavailableException(fr)',
      );
      expect(
        SpeechUnavailableException('fr', cause: StateError('x')).toString(),
        'SpeechUnavailableException(fr, cause: Bad state: x)',
      );
    });
  });
}

class _ThrowingStopOutput implements AudioOutput {
  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  Future<void> play(Uint8List bytes) async {}

  @override
  Future<void> setPlaybackRate(double rate) async {}

  @override
  Future<void> stop() async => throw StateError('stuck');

  @override
  Future<void> dispose() async {}
}
