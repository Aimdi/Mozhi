import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import 'helpers/fake_offline_recognizer.dart';
import 'helpers/fake_speech_recognizer.dart';

class _ThrowingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('read');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('write');

  @override
  Future<void> delete(String key) async {}
}

void main() {
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late MemoryStore store;
  late PrivacyMode privacy;
  late SpeechInputService service;
  late List<SpeechInputState> states;
  late List<SpeechInputResult> results;
  final owner = Object();

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  SpeechInputService build({
    bool withOffline = true,
    bool onDeviceSupported = true,
    KeyValueStore? keyValueStore,
  }) {
    final created = SpeechInputService(
      store: keyValueStore ?? store,
      adapter: system,
      offlineAdapter: withOffline ? whisper : null,
      privacyMode: () => privacy,
      platformSupported: true,
      onDeviceSupported: onDeviceSupported,
    );
    created.states.listen(states.add);
    created.results.listen(results.add);
    return created;
  }

  setUp(() {
    system = FakeSpeechRecognizer();
    whisper = FakeOfflineRecognizer();
    store = MemoryStore();
    privacy = PrivacyMode.offlineFirst;
    states = [];
    results = [];
    service = build();
  });

  tearDown(() => service.dispose());

  group('engine setting', () {
    test('defaults to the system recogniser', () async {
      await service.loadSettings();
      expect(service.engine.value, VoiceInputEngine.system);
      expect(service.isOfflineSupported, isTrue);
      expect(build(withOffline: false).isOfflineSupported, isFalse);
    });

    test('is loaded from and saved to the store', () async {
      store.values[SpeechInputService.engineKey] = 'whisper';
      final loaded = build();
      await loaded.loadSettings();
      expect(loaded.engine.value, VoiceInputEngine.whisper);

      await loaded.setEngine(VoiceInputEngine.system);
      expect(store.values[SpeechInputService.engineKey], 'system');
      expect(loaded.engine.value, VoiceInputEngine.system);
      await loaded.dispose();
    });

    test('ignores unknown stored values and store errors', () async {
      store.values[SpeechInputService.engineKey] = 'cloud';
      final unknown = build();
      await unknown.loadSettings();
      expect(unknown.engine.value, VoiceInputEngine.system);

      final failing = build(keyValueStore: _ThrowingStore());
      await failing.loadSettings();
      expect(failing.engine.value, VoiceInputEngine.system);
      await expectLater(
        failing.setEngine(VoiceInputEngine.whisper),
        throwsStateError,
      );
      // Kept for this session.
      expect(failing.engine.value, VoiceInputEngine.whisper);
    });

    test('keys round-trip', () {
      for (final engine in VoiceInputEngine.values) {
        expect(VoiceInputEngine.fromKey(engine.key), engine);
      }
      expect(VoiceInputEngine.fromKey(null), isNull);
    });

    test('forgetSettings goes back to the system recogniser', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      service.forgetSettings();
      expect(service.engine.value, VoiceInputEngine.system);
    });
  });

  group('routing', () {
    test('uses the system recogniser by default', () async {
      expect(await service.listen('en', owner: owner), isTrue);
      expect(system.initCalls, 1);
      expect(whisper.initCalls, 0);
      expect(system.lastRequest.onDevice, isFalse);
      expect(service.state, SpeechInputListening(owner: owner));
    });

    test('uses Whisper when chosen, on the device, with Whisper '
        'codes', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      expect(await service.listen('jv', owner: owner), isTrue);
      expect(system.initCalls, 0);
      expect(whisper.lastRequest.localeId, 'jw');
      expect(whisper.lastRequest.onDevice, isTrue);

      await service.cancel();
      await service.listen('auto');
      expect(whisper.lastRequest.localeId, isNull);
      expect(await service.locales(), whisper.localeList);
      expect(await service.localeIdFor('de-AT'), 'de');
    });

    test('explains a missing model without hiding voice input', () async {
      whisper.ready = false;
      await service.setEngine(VoiceInputEngine.whisper);
      expect(await service.listen('en', owner: owner), isFalse);
      expect(
        service.state,
        SpeechInputError(
          'offlineModelMissing',
          permanent: true,
          failure: SpeechInputFailure.offlineModelMissing,
          owner: owner,
        ),
      );
      expect(system.initCalls, 0);
      // initialize() alone says so too, without a state.
      await flush();
      states.clear();
      expect(await service.initialize(), isFalse);
      await flush();
      expect(states, isEmpty);
    });

    test('Offline only uses Whisper even with the system engine', () async {
      privacy = PrivacyMode.offlineOnly;
      expect(await service.listen('en'), isTrue);
      expect(whisper.initCalls, 1);
      expect(system.initCalls, 0);
    });

    test('Offline only never falls back to the system recogniser', () async {
      privacy = PrivacyMode.offlineOnly;
      whisper.ready = false;
      expect(await service.listen('en', owner: owner), isFalse);
      expect(
        service.state,
        isA<SpeechInputError>()
            .having(
              (s) => s.failure,
              'failure',
              SpeechInputFailure.offlineModelMissing,
            )
            .having((s) => s.isOwnedBy(owner), 'owner', isTrue),
      );
      expect(system.initCalls, 0);
      expect(whisper.initCalls, 0);
      expect(await service.initialize(), isFalse);
      expect(system.initCalls, 0);
    });

    test('Offline only without Whisper refuses voice input', () async {
      privacy = PrivacyMode.offlineOnly;
      final noWhisper = build(withOffline: false);
      expect(await noWhisper.listen('en', owner: owner), isFalse);
      expect(
        noWhisper.state,
        isA<SpeechInputError>().having(
          (s) => s.failure,
          'failure',
          SpeechInputFailure.offlineUnavailable,
        ),
      );
      expect(system.initCalls, 0);
      await noWhisper.dispose();
    });

    test('a broken readiness check counts as no model', () async {
      privacy = PrivacyMode.offlineOnly;
      whisper.readyError = Exception('disk');
      expect(await service.listen('en'), isFalse);
      expect(
        service.state,
        isA<SpeechInputError>().having(
          (s) => s.failure,
          'failure',
          SpeechInputFailure.offlineModelMissing,
        ),
      );
    });

    test('falls back to Whisper without a system recogniser', () async {
      system.initResult = false;
      expect(await service.listen('en'), isTrue);
      expect(system.initCalls, 1);
      expect(whisper.initCalls, 1);
      expect(service.state, const SpeechInputListening());
      await flush();
      expect(states.whereType<SpeechInputUnavailable>(), isEmpty);
    });

    test('without a system recogniser or model voice input is '
        'unavailable', () async {
      system.initResult = false;
      whisper.ready = false;
      expect(await service.listen('en'), isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      );
    });

    test('a denied permission is not worked around', () async {
      system
        ..initResult = false
        ..permission = false;
      expect(await service.listen('en'), isFalse);
      expect(whisper.initCalls, 0);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.permissionDenied,
        ),
      );
    });

    test('a fallback that fails keeps the system failure', () async {
      system.initResult = false;
      whisper.initResultWhenReady = false;
      expect(await service.initialize(), isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      );
    });

    test('Whisper is checked again for every session', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      await service.listen('en');
      await service.cancel();
      await service.listen('en');
      expect(whisper.initCalls, 2);
    });

    test('model or engine changes offer voice input again', () async {
      system.initResult = false;
      whisper.ready = false;
      await service.initialize();
      expect(service.state, isA<SpeechInputUnavailable>());

      whisper.ready = true;
      await service.offlineModelsChanged();
      expect(service.state, const SpeechInputIdle());

      system.initResult = false;
      whisper.ready = false;
      await service.initialize();
      await service.setEngine(VoiceInputEngine.whisper);
      expect(service.state, const SpeechInputIdle());
      // The same engine again changes nothing.
      await service.setEngine(VoiceInputEngine.whisper);
      expect(service.state, const SpeechInputIdle());
    });

    test('a successful initialize after a failure becomes idle', () async {
      system.initResult = false;
      whisper.ready = false;
      await service.initialize();
      whisper.ready = true;
      expect(await service.initialize(), isTrue);
      expect(service.state, const SpeechInputIdle());
    });
  });

  group('transcribing', () {
    setUp(() async {
      await service.setEngine(VoiceInputEngine.whisper);
      await service.listen('en', owner: owner);
      await flush();
      states.clear();
    });

    test('stop shows transcribing until the final result', () async {
      await service.stop();
      expect(whisper.stopCalls, 1);
      expect(service.state, SpeechInputTranscribing(owner: owner));
      expect(service.isListening, isFalse);
      expect(service.state.isOwnedBy(owner), isTrue);

      whisper
        ..emitResult('hello', isFinal: true)
        ..emitStatus(SpeechRecognizerStatus.done);
      await flush();
      expect(results, [
        SpeechInputResult('hello', isFinal: true, owner: owner),
      ]);
      expect(states, [
        SpeechInputTranscribing(owner: owner),
        const SpeechInputIdle(),
      ]);
    });

    test('an engine stopping on its own reports transcribing', () async {
      whisper
        ..emitLevel(-30)
        ..emitStatus(SpeechRecognizerStatus.transcribing);
      expect(service.state, SpeechInputTranscribing(owner: owner));
      // Not listening any more: levels are ignored, and it is still
      // transcribing until the result or an error.
      whisper
        ..emitLevel(-10)
        ..emitStatus(SpeechRecognizerStatus.notListening);
      expect(service.state, SpeechInputTranscribing(owner: owner));

      whisper.emitError('error_no_match', permanent: false);
      expect(
        service.state,
        SpeechInputError(
          'error_no_match',
          permanent: false,
          failure: SpeechInputFailure.noMatch,
          owner: owner,
        ),
      );
      // Late statuses change nothing.
      whisper
        ..emitStatus(SpeechRecognizerStatus.done)
        ..emitStatus(SpeechRecognizerStatus.transcribing);
      expect(service.state, isA<SpeechInputError>());
    });

    test('done without a result ends transcribing', () async {
      await service.stop();
      whisper.emitStatus(SpeechRecognizerStatus.done);
      expect(service.state, const SpeechInputIdle());
    });

    test('a missing model while transcribing is explained', () async {
      await service.stop();
      whisper.emitError(OfflineSpeechRecognizerAdapter.modelMissingCode);
      expect(
        service.state,
        isA<SpeechInputError>().having(
          (s) => s.failure,
          'failure',
          SpeechInputFailure.offlineModelMissing,
        ),
      );
    });

    test('cancel drops the transcription', () async {
      await service.stop();
      await service.cancel();
      expect(whisper.cancelCalls, 1);
      expect(service.state, const SpeechInputIdle());
      whisper.emitResult('late', isFinal: true);
      await flush();
      expect(results, isEmpty);
    });

    test('a new session cancels the transcription first', () async {
      await service.stop();
      expect(await service.listen('de', owner: owner), isTrue);
      expect(whisper.cancelCalls, 1);
      expect(service.state, SpeechInputListening(owner: owner));
    });

    test('stop twice is harmless', () async {
      await service.stop();
      await service.stop();
      expect(whisper.stopCalls, 1);
    });

    test('dispose cancels a transcription', () async {
      await service.stop();
      await service.dispose();
      expect(whisper.cancelCalls, 1);
    });
  });

  test('events of the recogniser not in use are ignored', () async {
    await service.listen('en');
    await service.cancel();
    await service.setEngine(VoiceInputEngine.whisper);
    await service.listen('en', owner: owner);
    system
      ..emitStatus(SpeechRecognizerStatus.done)
      ..emitError('error_network');
    expect(service.state, SpeechInputListening(owner: owner));
  });

  test('error codes of offline engines are classified', () {
    expect(
      classifySpeechError(OfflineSpeechRecognizerAdapter.modelMissingCode),
      SpeechInputFailure.offlineModelMissing,
    );
    expect(
      classifySpeechError(OfflineSpeechRecognizerAdapter.engineErrorCode),
      SpeechInputFailure.unknown,
    );
  });

  test('a session that started elsewhere meanwhile wins', () async {
    whisper.initGate = Completer();
    await service.setEngine(VoiceInputEngine.whisper);
    final first = service.listen('en');
    await flush();
    final second = service.listen('de');
    whisper.initGate!.complete();
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(whisper.lastRequest.localeId, 'de');
  });
}
