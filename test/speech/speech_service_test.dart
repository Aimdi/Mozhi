import 'dart:async';
import 'dart:convert';
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
  Error? rateError;
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
  Future<void> setPlaybackRate(double rate) async {
    if (rateError case final error?) throw error;
    rates.add(rate);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await completions.close();
  }
}

/// Records calls; [gates] hold the named step (`available`, `language`,
/// `rate`, `speak`) until completed. Without a speech engine by default, so
/// that Mozhi reads; tests about the device turn [supported] on.
class _FakeDeviceTts implements DeviceTts {
  bool supported = false;
  Set<String> languages = {'fr', 'en', 'he'};
  Map<String, List<DeviceVoice>> voicesByTag = {};
  Error? voicesError;
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

  /// The voice that reads when none is chosen ([activeVoice]).
  DeviceVoice? defaultVoice;
  DeviceVoice? _chosen;

  @override
  DeviceVoice? get activeVoice => _chosen ?? defaultVoice;

  @override
  Future<void> setLanguage(String languageTag, {DeviceVoice? voice}) {
    _chosen = voice;
    return _step(
      'language',
      [
        'language $languageTag',
        if (voice != null) 'voice ${voice.name}',
      ].join(' '),
    );
  }

  @override
  Future<void> setSpeechRate({required bool slow, double rate = 1}) => _step(
    'rate',
    [
      if (slow) 'rate slow' else 'rate normal',
      if (rate != 1) 'x$rate',
    ].join(' '),
  );

  @override
  Future<List<DeviceVoice>> voices(String languageTag) async {
    calls.add('voices $languageTag');
    if (voicesError case final error?) throw error;
    return voicesByTag[languageTag] ?? const [];
  }

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
      expect(service.deviceVoiceSupported, isFalse);

      device.supported = true;

      expect(service.deviceVoiceSupported, isTrue);
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

      test('plays slow clips at the slow playback speed', () async {
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

      test('every server failing is the cause it cannot read', () async {
        final allFailed = AllInstancesFailedException(
          'boom',
          engine: TranslationEngine.mozhi('google', 'Google'),
          instances: const [_instance],
          statusCode: 502,
        );
        when(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        ).thenThrow(allFailed);

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr', cause: same(allFailed))),
        );
        expect(service.current, isNull);
        expect(output.played, isEmpty);
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

    group('forgetLocalData', () {
      test('drops cached clips, the last utterance and the settings', () async {
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'en');
        expect(service.lastUtterance, isNotNull);
        await service.setSpeechRate(1.3);
        await service.setPreferDeviceVoice(enabled: true);
        // "Delete all local data" empties the store.
        await store.delete(SpeechService.settingsKey);
        await store.delete(SpeechService.preferDeviceKey);

        await service.forgetLocalData();

        expect(service.current, isNull);
        expect(service.lastUtterance, isNull);
        expect(service.settings, const SpeechSettings());
        expect(service.preferDeviceVoice, isFalse);
        expect(await service.loadSettings(), const SpeechSettings());
        expect(await service.loadPreferDeviceVoice(), isFalse);
        await service.toggle(id: 'a', text: 'Hi', languageCode: 'en');
        verify(() => repository.textToSpeech(text: 'Hi', languageCode: 'en'))
            .called(2);
      });
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

    group('device voice first', () {
      setUp(() => device.supported = true);

      test('speaks on the device and never asks Mozhi', () async {
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
        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        );

        expect(device.calls, contains('rate slow'));
      });

      test('passes the BCP-47 tag to the device', () async {
        await service.toggle(id: 'target', text: 'Shalom', languageCode: 'iw');

        expect(device.calls.first, 'available he');
      });

      test('uses Mozhi for a language without a device voice', () async {
        await service.toggle(id: 'target', text: 'Hallo', languageCode: 'de');

        expect(device.calls, ['available de']);
        expect(output.played, [_clip(1)]);
      });

      test('does not fall back to Mozhi when the device voice fails', () async {
        device.speakError = StateError('engine');

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr', cause: isStateError)),
        );

        expect(service.current, isNull);
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
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
          mozhiSupportsLanguage: (code) => code != 'de',
        );

        await expectLater(
          service.toggle(id: 'target', text: 'Hallo', languageCode: 'de'),
          throwsA(unavailable('de')),
        );
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

    group('privacy', () {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(
          'mozhi.example',
          engine: 'google',
        ),
        engineId: 'mozhi:google',
        source: 'fr',
        target: 'fr',
      );
      const offlineOnly = ConsentRequiredException(
        kind: ConsentKind.offlineOnly,
        destination: PublicInstanceDestination('mozhi.example'),
        engineId: 'mozhi:google',
        source: 'fr',
        target: 'fr',
      );

      setUpAll(() => registerFallbackValue(consent));
      setUp(() {
        when(() => repository.allowOnce(any())).thenAnswer((_) {});
      });

      test('reports the consent the privacy settings ask for', () async {
        when(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        ).thenThrow(consent);

        final error = await service
            .toggle(id: 'target', text: 'Bonjour', languageCode: 'fr')
            .then<Object?>((_) => null, onError: (Object e) => e);

        expect(error, unavailable('fr', cause: consent));
        expect((error! as SpeechUnavailableException).onlineConsent, consent);
        expect(service.current, isNull);
      });

      test('offers nothing in offline-only mode', () {
        expect(
          const SpeechUnavailableException(
            'fr',
            cause: offlineOnly,
          ).onlineConsent,
          isNull,
        );
        expect(
          SpeechUnavailableException(
            'fr',
            cause: StateError('x'),
          ).onlineConsent,
          isNull,
        );
      });

      test('allowOnline grants the approval right before the clip', () async {
        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: consent,
        );

        verifyInOrder([
          () => repository.allowOnce(consent),
          () => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'),
        ]);
        expect(output.played, [_clip(1)]);
      });

      test('every chunk of a long text gets the approval', () async {
        final sentences = ['${'un ' * 60}fin.', '${'deux ' * 30}fin.'];

        await service.speak(
          id: 'target',
          text: sentences.join(' '),
          languageCode: 'fr',
          allowOnline: consent,
        );
        await flush();

        verify(() => repository.allowOnce(consent)).called(2);
      });

      test('cached clips and replays need no new request', () async {
        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: consent,
        );
        output.complete();
        await flush();

        expect(await service.replaySlowly(), isTrue);

        verify(() => repository.allowOnce(consent)).called(1);
        expect(output.played, [_clip(1), _clip(1)]);
      });

      test('ignores an offline-only approval', () async {
        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: offlineOnly,
        );

        verifyNever(() => repository.allowOnce(any()));
      });

      test('a device voice needs no approval', () async {
        device.supported = true;

        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: consent,
        );

        expect(device.calls.last, 'speak Bonjour');
        verifyNever(() => repository.allowOnce(any()));
      });
    });

    group('failures', () {
      setUp(
        () => device
          ..supported = true
          ..languages = {},
      );

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

      test('device only: never uses Mozhi', () async {
        await service.setPreferDeviceVoice(enabled: true);

        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(unavailable('fr')),
        );
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
      });

      test('device only still reads with a device voice', () async {
        device.supported = true;
        await store.write(SpeechService.preferDeviceKey, 'true');

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls.last, 'speak Bonjour');
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
          device
            ..supported = true
            ..languages = {'en'};

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
        setUp(() {
          device.supported = true;
          when(() => repository.instances).thenReturn(const []);
        });

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
          // No device voice for German: Mozhi reads it.
          await service.toggle(id: 'source', text: 'Hallo', languageCode: 'de');
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

      group('a failing chunk', () {
        test('makes the first one throw', () async {
          stubTts(text: sentences[0], answer: StateError('offline'));

          await expectLater(
            speak(),
            throwsA(unavailable('en', cause: isStateError)),
          );

          expect(output.played, isEmpty);
          expect(service.current, isNull);
        });

        test('ends the playback after the current chunk', () async {
          stubTts(text: sentences[1], answer: StateError('offline'));

          await speak();
          await flush();

          expect(output.stops, 0);
          expect(service.current, 'target');

          output.complete();
          await flush();

          expect(output.played, [_clip(1)]);
          expect(device.calls, isEmpty);
          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('that fails between chunks ends the playback', () async {
          final fetch = Completer<Uint8List>();
          stubTts(text: sentences[1], answer: () => fetch.future);
          await speak();
          output.complete();
          await flush();
          expect(service.current, 'target');

          fetch.completeError(StateError('offline'));
          await flush();

          expect(output.stops, 0);
          expect(service.current, isNull);
        });

        test('that cannot play ends the playback', () async {
          await speak();
          output
            ..playError = StateError('codec')
            ..complete();
          await flush();

          expect(output.played, [_clip(1)]);
          expect(service.current, isNull);
        });

        test('that cannot play after stop changes nothing', () async {
          await speak();
          output
            ..playGate = Completer<void>()
            ..playError = StateError('codec')
            ..complete();
          await flush();
          await service.stop();
          output.playGate!.complete();
          await flush();

          expect(service.current, isNull);
          expect(emitted, ['target', null]);
        });

        test('is ignored after stop', () async {
          final fetch = Completer<Uint8List>();
          stubTts(text: sentences[1], answer: () => fetch.future);
          await speak();
          await service.stop();

          fetch.completeError(StateError('offline'));
          await flush();

          expect(device.calls, isEmpty);
          expect(service.current, isNull);
        });
      });
    });

    group('settings', () {
      const amelie = DeviceVoice(name: 'Amélie', locale: 'fr-CA');

      test('are the defaults until loaded', () async {
        await store.write(
          SpeechService.settingsKey,
          '{"rate": 1.3, "voices": {"fr": {"name": "Amélie", '
          '"locale": "fr-CA"}}}',
        );

        expect(service.settings, const SpeechSettings());
        final loaded = await service.loadSettings();
        expect(loaded.rate, 1.3);
        expect(loaded.voiceFor('fr'), amelie);
        expect(service.settings, loaded);
      });

      test('read the store once', () async {
        final store = _MockKeyValueStore();
        when(() => store.read(any())).thenAnswer((_) async => null);
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: store,
        );

        await service.loadSettings();
        await service.loadSettings();

        verify(() => store.read(SpeechService.settingsKey)).called(1);
      });

      test('read as defaults when invalid, failing or missing', () async {
        await store.write(SpeechService.settingsKey, '[1, 2]');
        expect(await service.loadSettings(), const SpeechSettings());

        final broken = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: MemoryStore({SpeechService.settingsKey: '{oops'}),
        );
        expect(await broken.loadSettings(), const SpeechSettings());

        final failingStore = _MockKeyValueStore();
        when(() => failingStore.read(any())).thenThrow(Exception('locked'));
        final failing = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: failingStore,
        );
        expect(await failing.loadSettings(), const SpeechSettings());

        final storeless = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
        );
        expect(await storeless.loadSettings(), const SpeechSettings());
      });

      test('setSpeechRate normalises, applies and persists', () async {
        await service.setSpeechRate(1.27);

        expect(service.settings.rate, 1.3);
        final stored = SpeechSettings.fromJson(
          jsonDecode(store.values[SpeechService.settingsKey]!)
              as Map<String, dynamic>,
        );
        expect(stored.rate, 1.3);
      });

      test('setVoice keeps the other stored settings', () async {
        await store.write(
          SpeechService.settingsKey,
          jsonEncode(const SpeechSettings(rate: 0.8).toJson()),
        );

        await service.setVoice('fr', amelie);

        expect(service.settings, isA<SpeechSettings>());
        expect(service.settings.rate, 0.8);
        expect(service.settings.voiceFor('fr'), amelie);
        expect(
          store.values[SpeechService.settingsKey],
          jsonEncode(service.settings.toJson()),
        );

        await service.setVoice('fr', null);
        expect(service.settings.voices, isEmpty);
      });

      test('skips writing unchanged settings', () async {
        final store = _MockKeyValueStore();
        when(() => store.read(any())).thenAnswer((_) async => null);
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: store,
        );

        await service.setSpeechRate(1);
        await service.setVoice('Pirate', amelie);

        verifyNever(() => store.write(any(), any()));
      });

      test('apply changes even when they cannot be saved', () async {
        final store = _MockKeyValueStore();
        when(() => store.read(any())).thenAnswer((_) async => null);
        when(() => store.write(any(), any())).thenThrow(Exception('full'));
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: store,
        );

        await expectLater(service.setSpeechRate(0.7), throwsException);

        expect(service.settings.rate, 0.7);
        expect(await service.loadSettings(), service.settings);
      });

      test('Mozhi clips play at the chosen rate', () async {
        await service.setSpeechRate(1.2);

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(output.rates, [1.2]);
      });

      test('slow Mozhi clips play at a fraction of the rate', () async {
        await service.setSpeechRate(0.5);

        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        );

        expect(output.rates.single, closeTo(0.3, 1e-9));
      });

      test('Mozhi still plays when the player cannot change speed', () async {
        output.rateError = UnsupportedError('no rate');
        await service.setSpeechRate(1.2);

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(output.played, [_clip(1)]);
        expect(device.calls, isEmpty);
      });

      test('the device speaks at the chosen rate', () async {
        device.supported = true;
        await service.setSpeechRate(1.4);

        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        );

        expect(device.calls, contains('rate slow x1.4'));
      });

      test('a chosen voice reads its language on the device', () async {
        device.supported = true;
        await service.setVoice('fr', amelie);

        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(device.calls, [
          'available fr',
          'language fr voice Amélie',
          'rate normal',
          'speak Bonjour',
        ]);
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
      });

      test('voices are looked up by the device tag', () async {
        device.supported = true;
        await service.setVoice('he', amelie);

        await service.toggle(id: 'target', text: 'שלום', languageCode: 'iw');

        expect(device.calls, contains('language he voice Amélie'));
      });

      test('other languages keep the default voice', () async {
        device.supported = true;
        await service.setVoice('fr', amelie);

        await service.toggle(id: 'target', text: 'Hello', languageCode: 'en');

        expect(device.calls, contains('language en'));
      });

      test('Mozhi reads the language when the voice is unavailable', () async {
        device.supported = true;
        await service.setVoice('de', amelie);

        await service.toggle(id: 'target', text: 'Hallo', languageCode: 'de');

        expect(device.calls, ['available de']);
        expect(output.played, [_clip(1)]);
      });
    });

    group('deviceVoices', () {
      const voice = DeviceVoice(name: 'Amélie', locale: 'fr-CA');

      test('lists the device voices by device tag', () async {
        device
          ..supported = true
          ..voicesByTag = {
            'he': [voice],
          };

        expect(await service.deviceVoices('iw'), [voice]);
        expect(device.calls, ['voices he']);
      });

      test('is empty for unspeakable codes or without an engine', () async {
        expect(await service.deviceVoices('Pirate'), isEmpty);

        device.supported = false;
        expect(await service.deviceVoices('fr'), isEmpty);
        expect(device.calls, isEmpty);
      });

      test('is empty when the engine fails', () async {
        device
          ..supported = true
          ..voicesError = StateError('engine');

        expect(await service.deviceVoices('fr'), isEmpty);
      });
    });

    group('speak', () {
      test('restarts the playing id instead of stopping it', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        await service.speak(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        );

        expect(output.stops, 1);
        expect(output.played, [_clip(1), _clip(1)]);
        expect(output.rates, [1, SpeechService.slowPlaybackRate]);
        expect(service.current, 'target');
        expect(emitted, ['target']);
      });

      test('only stops for empty text', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');

        await service.speak(id: 'target', text: ' ', languageCode: 'fr');

        expect(service.current, isNull);
        expect(service.lastUtterance?.text, 'Bonjour');
      });
    });

    group('replaySlowly', () {
      test('does nothing before anything was read aloud', () async {
        expect(service.lastUtterance, isNull);
        expect(await service.replaySlowly(), isFalse);
        expect(output.played, isEmpty);
      });

      test('replays the last utterance slowly from the cache', () async {
        await service.toggle(
          id: 'target',
          text: ' Bonjour ',
          languageCode: 'fr',
        );
        output.complete();
        await flush();
        expect(service.current, isNull);

        expect(await service.replaySlowly(), isTrue);

        expect(
          service.lastUtterance,
          const SpeechUtterance(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
          ),
        );
        expect(service.current, 'target');
        expect(output.rates, [1, SpeechService.slowPlaybackRate]);
        verify(
          () => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'),
        ).called(1);
      });

      test('replays while the utterance is still playing', () async {
        await service.toggle(id: 'source', text: 'Hola', languageCode: 'es');

        await service.replaySlowly();

        expect(service.current, 'source');
        expect(output.played, hasLength(2));
      });

      test('throws when nothing can read the text anymore', () async {
        await service.toggle(id: 'target', text: 'Hallo', languageCode: 'de');
        when(() => repository.instances).thenReturn(const []);
        device.languages = {};

        await expectLater(service.replaySlowly(), throwsA(unavailable('de')));
        expect(service.current, isNull);
      });
    });

    group('lastUtterance', () {
      const bonjour = SpeechUtterance(
        id: 'target',
        text: 'Bonjour',
        languageCode: 'fr',
      );

      test('is set once the device engine has started', () async {
        device.supported = true;

        await service.speak(id: 'target', text: 'Bonjour', languageCode: 'fr');

        expect(service.lastUtterance, bonjour);
      });

      test('ignores reads that are not remembered', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
        output.complete();
        await flush();

        await service.toggle(
          id: 'settings.speech.rate',
          text: 'Sample sentence',
          languageCode: 'en',
          remember: false,
        );
        await service.speak(
          id: 'settings.speech.rate',
          text: 'Sample sentence',
          languageCode: 'en',
          remember: false,
        );

        expect(service.lastUtterance, bonjour);
        await service.replaySlowly();
        verify(
          () => repository.textToSpeech(text: 'Bonjour', languageCode: 'fr'),
        ).called(1);
      });

      test('ignores reads that fail', () async {
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
        when(() => repository.instances).thenReturn(const []);
        device.languages = {};

        await expectLater(
          service.toggle(id: 'source', text: 'Hallo', languageCode: 'de'),
          throwsA(unavailable('de')),
        );

        expect(service.lastUtterance, bonjour);
      });

      test('ignores reads stopped before they started', () async {
        final clip = Completer<Uint8List>();
        stubTts(answer: () => clip.future);

        final reading = service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
        );
        await flush();
        await service.stop();
        clip.complete(_clip(1));
        await reading;

        expect(service.lastUtterance, isNull);
        expect(await service.replaySlowly(), isFalse);
      });
    });

    group('previewVoice', () {
      const amelie = DeviceVoice(name: 'Amélie', locale: 'fr-CA');

      setUp(() => device.supported = true);

      test('reads with the given voice on the device only', () async {
        await service.previewVoice(
          id: 'preview',
          text: 'Français',
          languageCode: 'fr',
          voice: amelie,
        );

        expect(device.calls, [
          'available fr',
          'language fr voice Amélie',
          'rate normal',
          'speak Français',
        ]);
        expect(service.current, 'preview');
        expect(service.lastUtterance, isNull);
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
      });

      test('uses the default voice when none is given', () async {
        await service.setVoice('fr', amelie);

        await service.previewVoice(
          id: 'preview',
          text: 'Français',
          languageCode: 'fr',
        );

        expect(device.calls, contains('language fr'));
      });

      test('toggles off when previewed again', () async {
        await service.previewVoice(
          id: 'preview',
          text: 'Français',
          languageCode: 'fr',
        );
        await service.previewVoice(
          id: 'preview',
          text: 'Français',
          languageCode: 'fr',
        );

        expect(service.current, isNull);
      });

      test('throws without a device voice for the language', () async {
        await expectLater(
          service.previewVoice(
            id: 'preview',
            text: 'Deutsch',
            languageCode: 'de',
          ),
          throwsA(unavailable('de')),
        );
        expect(output.played, isEmpty);
      });
    });

    group('online voices', () {
      const google = DeviceVoice(
        name: 'Google français',
        locale: 'fr-FR',
        networkRequired: true,
      );
      const local = DeviceVoice(name: 'Amélie', locale: 'fr-CA');

      setUpAll(
        () => registerFallbackValue(SpeechService.onlineVoiceConsent(google)),
      );

      setUp(() {
        device
          ..supported = true
          ..defaultVoice = google;
        when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineFirst);
      });

      Matcher asks(ConsentKind kind) => isA<SpeechUnavailableException>()
          .having((e) => e.languageCode, 'languageCode', 'fr')
          .having(
            (e) => e.cause,
            'cause',
            isA<ConsentRequiredException>()
                .having((c) => c.kind, 'kind', kind)
                .having((c) => c.engineId, 'engineId', 'voice:${google.id}')
                .having(
                  (c) => c.destination,
                  'destination',
                  const CloudProviderDestination('Google'),
                ),
          );

      test('asks before an online voice reads, then remembers it', () async {
        Object? error;
        try {
          await service.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
          );
        } on Object catch (e) {
          error = e;
        }
        expect(error, asks(ConsentKind.cloudProvider));
        final consent = (error! as SpeechUnavailableException).onlineConsent!;
        expect(SpeechService.isOnlineVoiceConsent(consent), isTrue);
        expect(SpeechService.onlineVoiceOf(consent)?.name, 'Google français');
        expect(device.calls, isNot(contains('speak Bonjour')));
        expect(service.current, isNull);
        verifyNever(
          () => repository.textToSpeech(
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
        verifyNever(() => repository.allowOnce(any()));

        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: consent,
        );
        expect(device.calls.last, 'speak Bonjour');
        expect(service.settings.allowsOnlineVoice(google), isTrue);
        expect(
          jsonDecode((await store.read(SpeechService.settingsKey))!),
          containsPair('onlineVoices', [google.id]),
        );
        expect(service.lastUtterance?.text, 'Bonjour');

        await service.stop();
        await service.toggle(id: 'target', text: 'Encore', languageCode: 'fr');
        expect(device.calls.last, 'speak Encore');
      });

      test('a voice on the device reads without asking', () async {
        device.defaultVoice = local;
        await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
        expect(device.calls.last, 'speak Bonjour');
      });

      test('a consent for another voice does not count', () async {
        await expectLater(
          service.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
            allowOnline: SpeechService.onlineVoiceConsent(
              const DeviceVoice(
                name: 'Google UK',
                locale: 'en-GB',
                networkRequired: true,
              ),
            ),
          ),
          throwsA(asks(ConsentKind.cloudProvider)),
        );
      });

      test('never read in offline-only mode, not even a preview', () async {
        when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineOnly);
        await service.setVoice('fr', google);
        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(asks(ConsentKind.offlineOnly)),
        );
        final offlineOnly = SpeechService.onlineVoiceConsent(
          google,
          kind: ConsentKind.offlineOnly,
        );
        await expectLater(
          service.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
            allowOnline: offlineOnly,
          ),
          throwsA(asks(ConsentKind.offlineOnly)),
        );
        await expectLater(
          service.previewVoice(
            id: 'preview',
            text: 'Français',
            languageCode: 'fr',
            voice: google,
          ),
          throwsA(asks(ConsentKind.offlineOnly)),
        );
        expect(device.calls, isNot(contains(startsWith('speak'))));
      });

      test('previews read without asking', () async {
        await service.previewVoice(
          id: 'preview',
          text: 'Français',
          languageCode: 'fr',
          voice: google,
        );
        expect(device.calls.last, 'speak Français');
        expect(service.settings.onlineVoices, isEmpty);
      });

      test('forgetOnlineVoices asks again', () async {
        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: SpeechService.onlineVoiceConsent(google),
        );
        await service.forgetOnlineVoices();
        await service.stop();

        expect(service.settings.onlineVoices, isEmpty);
        await expectLater(
          service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr'),
          throwsA(asks(ConsentKind.cloudProvider)),
        );
      });

      test('an approval that cannot be saved applies until restart', () async {
        final failing = _MockKeyValueStore();
        when(() => failing.read(any())).thenAnswer((_) async => null);
        when(() => failing.write(any(), any())).thenThrow(StateError('full'));
        final service = SpeechService(
          repository: repository,
          output: output,
          deviceTts: device,
          store: failing,
        );
        addTearDown(service.dispose);

        await service.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: SpeechService.onlineVoiceConsent(google),
        );
        expect(device.calls.last, 'speak Bonjour');
        expect(service.settings.allowsOnlineVoice(google), isTrue);
      });

      test('onlineVoiceOf reads only voice consents', () {
        expect(
          SpeechService.onlineVoiceOf(
            const ConsentRequiredException(
              kind: ConsentKind.pair,
              destination: PublicInstanceDestination('mozhi.example'),
              engineId: 'mozhi:google',
            ),
          ),
          isNull,
        );
        final voice = SpeechService.onlineVoiceOf(
          const ConsentRequiredException(
            kind: ConsentKind.cloudProvider,
            destination: CloudProviderDestination(''),
            engineId: 'voice:odd',
          ),
        );
        expect((voice?.name, voice?.locale), ('odd', ''));
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
