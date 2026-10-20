import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:speech_to_text/speech_to_text.dart';

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
  late FakeSpeechRecognizer recognizer;
  late MemoryStore store;
  late SpeechInputService service;
  late List<SpeechInputState> states;
  late List<SpeechInputResult> results;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  SpeechInputService build({
    bool platformSupported = true,
    bool onDeviceSupported = true,
    KeyValueStore? keyValueStore,
    Duration queryTimeout = SpeechInputService.defaultQueryTimeout,
    Duration initializeTimeout = SpeechInputService.defaultInitializeTimeout,
  }) {
    final created = SpeechInputService(
      store: keyValueStore ?? store,
      adapter: recognizer,
      platformSupported: platformSupported,
      onDeviceSupported: onDeviceSupported,
      queryTimeout: queryTimeout,
      initializeTimeout: initializeTimeout,
    );
    created.states.listen(states.add);
    created.results.listen(results.add);
    return created;
  }

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    store = MemoryStore();
    states = [];
    results = [];
    service = build();
  });

  group('platform support', () {
    test('speech input is supported everywhere but Linux and Fuchsia', () {
      expect(isSpeechInputPlatformSupported(isWeb: true), isTrue);
      for (final platform in TargetPlatform.values) {
        expect(
          isSpeechInputPlatformSupported(isWeb: false, platform: platform),
          platform != TargetPlatform.linux &&
              platform != TargetPlatform.fuchsia,
          reason: '$platform',
        );
      }
    });

    test('on-device recognition is limited to Android and Apple', () {
      expect(isOnDeviceSpeechSupported(isWeb: true), isFalse);
      for (final platform in TargetPlatform.values) {
        expect(
          isOnDeviceSpeechSupported(isWeb: false, platform: platform),
          {
            TargetPlatform.android,
            TargetPlatform.iOS,
            TargetPlatform.macOS,
          }.contains(platform),
          reason: '$platform',
        );
      }
    });

    test('creates the plugin adapter lazily by default', () async {
      final created = SpeechInputService(store: store);
      expect(created.state, const SpeechInputIdle());
      await created.dispose();
    });

    test('defaults follow the test platform (Android)', () {
      final created = SpeechInputService(store: store, adapter: recognizer);
      expect(created.isPlatformSupported, isTrue);
      expect(created.isOnDeviceSupported, isTrue);
      expect(created.state, const SpeechInputIdle());
    });

    test('unsupported platform is unavailable without touching the '
        'recogniser', () async {
      service = build(platformSupported: false);
      expect(service.state, const SpeechInputUnavailable());
      expect(service.isOnDeviceSupported, isFalse);
      expect(await service.initialize(), isFalse);
      expect(await service.listen('en'), isFalse);
      expect(await service.locales(), isEmpty);
      expect(recognizer.initCalls, 0);
    });
  });

  group('initialize', () {
    test('succeeds once and is cached', () async {
      expect(service.isAvailable, isNull);
      final outcomes = await Future.wait([
        service.initialize(),
        service.initialize(),
      ]);
      expect(outcomes, [true, true]);
      expect(await service.initialize(), isTrue);
      expect(recognizer.initCalls, 1);
      expect(service.isAvailable, isTrue);
      expect(service.state, const SpeechInputIdle());
      expect(states, isEmpty);
    });

    test('without permission reports permissionDenied', () async {
      recognizer
        ..initResult = false
        ..permission = false;
      expect(await service.initialize(), isFalse);
      expect(service.isAvailable, isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.permissionDenied,
        ),
      );
      await flush();
      expect(states, [service.state]);
    });

    test('with permission reports recognizerUnavailable', () async {
      recognizer.initResult = false;
      expect(await service.initialize(), isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      );
    });

    test('treats a failing permission check as granted', () async {
      recognizer
        ..initResult = false
        ..permissionError = Exception('no');
      await service.initialize();
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      );
    });

    test('uses errors reported during initialisation as the reason '
        'without emitting error states', () async {
      recognizer
        ..initResult = false
        ..permission = false
        ..initErrors = [
          const SpeechRecognizerError('error_client', permanent: true),
          const SpeechRecognizerError('not supported', permanent: true),
        ];
      await service.initialize();
      await flush();
      expect(states, [
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      ]);
    });

    test('treats a throwing recogniser as unavailable', () async {
      recognizer.initError = Exception('channel');
      expect(await service.initialize(), isFalse);
      expect(service.state, isA<SpeechInputUnavailable>());
    });

    test('retries after a failure and becomes idle on success', () async {
      recognizer.initResult = false;
      await service.initialize();
      recognizer.initResult = true;
      expect(await service.initialize(), isTrue);
      expect(recognizer.initCalls, 2);
      expect(service.state, const SpeechInputIdle());
    });
  });

  group('refreshAvailability', () {
    test('offers voice input again once permission is granted', () async {
      recognizer
        ..initResult = false
        ..permission = false;
      await service.initialize();

      await service.refreshAvailability();
      expect(service.state, isA<SpeechInputUnavailable>());

      recognizer.permission = true;
      await service.refreshAvailability();
      expect(service.state, const SpeechInputIdle());
      expect(service.isAvailable, isNull);

      recognizer.initResult = true;
      expect(await service.listen('en'), isTrue);
    });

    test('ignores other states and failures', () async {
      await service.refreshAvailability();
      expect(service.state, const SpeechInputIdle());

      recognizer.initResult = false;
      await service.initialize();
      await service.refreshAvailability();
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      );
    });
  });

  group('locales', () {
    test('are fetched once after initialising', () async {
      expect(await service.locales(), recognizer.localeList);
      expect(await service.locales(), recognizer.localeList);
      expect(recognizer.localeCalls, 1);
      expect(recognizer.initCalls, 1);
    });

    test('are empty when the recogniser fails', () async {
      recognizer.localesError = Exception('locales');
      expect(await service.locales(), isEmpty);
    });

    test('map Mozhi codes to recogniser ids', () async {
      expect(await service.localeIdFor('en-GB'), 'en_GB');
      expect(await service.localeIdFor('pt'), 'pt_BR');
      expect(await service.localeIdFor('en'), 'en_US');
      expect(await service.localeIdFor('auto'), isNull);
      expect(await service.localeIdFor('ja'), isNull);
      expect(await service.localeIdFor(null), isNull);
    });

    test('prefer the system locale for bare languages', () async {
      recognizer.systemLocale = 'en_GB';
      expect(await service.localeIdFor('en'), 'en_GB');
    });
  });

  group('unanswered platform queries', () {
    const timeout = Duration(milliseconds: 30);

    test('have short defaults; initialising may take a minute', () {
      expect(
        SpeechInputService.defaultQueryTimeout,
        const Duration(seconds: 3),
      );
      expect(
        SpeechInputService.defaultInitializeTimeout,
        const Duration(minutes: 1),
      );
      expect(service.queryTimeout, SpeechInputService.defaultQueryTimeout);
      expect(
        service.initializeTimeout,
        SpeechInputService.defaultInitializeTimeout,
      );
    });

    test('unanswered locales: listening starts in the chosen language, '
        'and later sessions do not wait again', () async {
      recognizer.localesGate = Completer<void>();
      service = build(queryTimeout: timeout);
      final owner = Object();

      final elapsed = Stopwatch()..start();
      expect(await service.listen('fr', owner: owner), isTrue);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(recognizer.lastRequest.localeId, 'fr-FR');
      expect(service.state, SpeechInputListening(owner: owner));

      await service.cancel();
      expect(await service.listen('pt'), isTrue);
      expect(recognizer.lastRequest.localeId, 'pt-BR');
      expect(await service.locales(), isEmpty);
      expect(await service.localeIdFor('fr'), 'fr-FR');
      await service.listen('auto');
      expect(recognizer.lastRequest.localeId, isNull);
      expect(recognizer.localeCalls, 1);
    });

    test('an unanswered system locale is left out', () async {
      recognizer
        ..systemLocale = 'en_GB'
        ..systemLocaleGate = Completer<void>();
      service = build(queryTimeout: timeout);
      expect(await service.listen('en'), isTrue);
      // en_GB would have won as the system locale.
      expect(recognizer.lastRequest.localeId, 'en_US');
      await service.cancel();
      expect(await service.listen('fr'), isTrue);
      expect(recognizer.lastRequest.localeId, 'fr_FR');
      expect(recognizer.systemLocaleCalls, 1);
    });

    test('an unanswered permission check counts as granted', () async {
      recognizer
        ..initResult = false
        ..permissionGate = Completer<void>();
      service = build(queryTimeout: timeout);
      expect(await service.initialize(), isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.recognizerUnavailable,
        ),
      );
    });

    test('an initialisation that never ends fails after '
        'initializeTimeout, and the next session tries again', () async {
      recognizer.initGate = Completer<void>();
      service = build(initializeTimeout: timeout);
      final owner = Object();

      expect(await service.listen('en', owner: owner), isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(failure: SpeechInputFailure.unknown),
      );
      expect(recognizer.requests, isEmpty);

      recognizer.initGate = null;
      expect(await service.listen('en', owner: owner), isTrue);
      expect(recognizer.initCalls, 2);
      expect(service.state, SpeechInputListening(owner: owner));
    });

    test('an error reported before the initialisation timed out explains '
        'it', () async {
      recognizer
        ..initGate = Completer<void>()
        ..initResult = false;
      service = build(initializeTimeout: timeout);
      final pending = service.initialize();
      await flush();
      recognizer.emitError('error_permission');
      expect(await pending, isFalse);
      expect(
        service.state,
        const SpeechInputUnavailable(
          failure: SpeechInputFailure.permissionDenied,
        ),
      );
    });
  });

  group('listen', () {
    test('starts a dictation session with the mapped locale', () async {
      final owner = Object();
      expect(await service.listen('fr', owner: owner), isTrue);
      expect(
        recognizer.lastRequest,
        const SpeechListenRequest(localeId: 'fr_FR'),
      );
      expect(recognizer.lastRequest.partialResults, isTrue);
      expect(recognizer.lastRequest.listenMode, ListenMode.dictation);
      expect(recognizer.lastRequest.pauseFor, const Duration(seconds: 3));
      expect(recognizer.lastRequest.listenFor, const Duration(seconds: 60));
      expect(recognizer.lastRequest.onDevice, isFalse);
      expect(service.isListening, isTrue);
      expect(service.state, SpeechInputListening(owner: owner));
      expect(service.state.isOwnedBy(owner), isTrue);
      expect(service.state.isOwnedBy(Object()), isFalse);
    });

    test('uses the system default for auto and unknown languages', () async {
      await service.listen('auto');
      expect(recognizer.lastRequest.localeId, isNull);
      await service.listen(null);
      expect(recognizer.lastRequest.localeId, isNull);
    });

    test('fails when the recogniser is unavailable', () async {
      recognizer.initResult = false;
      expect(await service.listen('en'), isFalse);
      expect(recognizer.requests, isEmpty);
      expect(service.state, isA<SpeechInputUnavailable>());
    });

    test('streams partial and final results', () async {
      final owner = Object();
      await service.listen('en', owner: owner);
      recognizer
        ..emitResult('hello')
        ..emitResult('hello world');
      await flush();
      expect(
        service.state,
        SpeechInputListening(
          partialText: 'hello world',
          owner: owner,
          heardSpeech: true,
        ),
      );

      recognizer.emitResult('Hello world.', isFinal: true);
      await flush();
      expect(results, [
        SpeechInputResult('hello', isFinal: false, owner: owner),
        SpeechInputResult('hello world', isFinal: false, owner: owner),
        SpeechInputResult('Hello world.', isFinal: true, owner: owner),
      ]);
      expect(service.state, const SpeechInputIdle());
      expect(service.isListening, isFalse);
    });

    test('words are speech, loudness alone is not', () async {
      final owner = Object();
      await service.listen('en', owner: owner);
      recognizer
        ..emitLevel(-2)
        ..emitLevel(10)
        ..emitResult(' ');
      await flush();
      expect(
        service.state,
        SpeechInputListening(level: 1, partialText: ' ', owner: owner),
      );
      recognizer.emitResult('hi');
      await flush();
      expect((service.state as SpeechInputListening).heardSpeech, isTrue);
      // Once heard, it stays heard.
      recognizer.emitResult('');
      await flush();
      expect((service.state as SpeechInputListening).heardSpeech, isTrue);
    });

    test('normalises sound levels to 0..1', () async {
      await service.listen('en');
      recognizer
        ..emitLevel(-2)
        ..emitLevel(3)
        ..emitLevel(8)
        ..emitLevel(double.nan)
        ..emitLevel(-2);
      await flush();
      final levels = [
        for (final state in states)
          if (state is SpeechInputListening) state.level,
      ];
      expect(levels, [0, 0.5, 1, 0]);
    });

    test('ignores sound levels and statuses outside a session', () async {
      await service.listen('en');
      await service.stop();
      states.clear();
      recognizer
        ..emitLevel(10)
        ..emitStatus(SpeechRecognizerStatus.listening)
        ..emitStatus(SpeechRecognizerStatus.done);
      await flush();
      expect(states, isEmpty);
    });

    test('follows recogniser statuses', () async {
      final owner = Object();
      await service.listen('en', owner: owner);
      recognizer.emitStatus(SpeechRecognizerStatus.listening);
      await flush();
      expect(states, [SpeechInputListening(owner: owner)]);

      recognizer.emitStatus(SpeechRecognizerStatus.notListening);
      await flush();
      expect(service.state, const SpeechInputIdle());

      // A late final result is still delivered.
      recognizer.emitResult('late', isFinal: true);
      await flush();
      expect(
        results.single,
        SpeechInputResult('late', isFinal: true, owner: owner),
      );
      expect(service.state, const SpeechInputIdle());
    });

    test('ignores statuses once the session ended', () async {
      await service.listen('en');
      recognizer.emitStatus(SpeechRecognizerStatus.done);
      await flush();
      expect(service.state, const SpeechInputIdle());
      // The status is ignored once the session ended.
      recognizer.emitStatus(SpeechRecognizerStatus.listening);
      expect(service.state, const SpeechInputIdle());
    });

    test('cancels a running session before starting another', () async {
      final first = Object();
      final second = Object();
      await service.listen('en', owner: first);
      expect(await service.listen('fr', owner: second), isTrue);
      expect(recognizer.cancelCalls, 1);
      expect(service.state, SpeechInputListening(owner: second));
    });

    test('a newer listen supersedes one that is still starting', () async {
      recognizer.initGate = Completer<void>();
      final first = service.listen('en');
      final second = service.listen('fr');
      recognizer.initGate!.complete();
      expect(await first, isFalse);
      expect(await second, isTrue);
      expect(recognizer.requests.single.localeId, 'fr_FR');
    });

    test('cancel while starting aborts the session', () async {
      recognizer.initGate = Completer<void>();
      final pending = service.listen('en');
      await service.cancel();
      recognizer.initGate!.complete();
      expect(await pending, isFalse);
      expect(recognizer.requests, isEmpty);
      expect(service.state, const SpeechInputIdle());
    });

    test('reports a failed start as an error', () async {
      final owner = Object();
      recognizer.listenError = Exception('busy');
      expect(await service.listen('en', owner: owner), isFalse);
      expect(
        service.state,
        SpeechInputError('Exception: busy', permanent: false, owner: owner),
      );
      expect(service.isListening, isFalse);
    });

    test('a failed start that was cancelled stays quiet', () async {
      recognizer
        ..listenError = Exception('busy')
        ..listenGate = Completer<void>();
      final pending = service.listen('en');
      await flush();
      expect(service.isListening, isTrue);
      await service.cancel();
      recognizer.listenGate!.complete();
      expect(await pending, isFalse);
      expect(service.state, const SpeechInputIdle());
    });

    test('a session cancelled while starting reports false', () async {
      recognizer.listenGate = Completer<void>();
      final pending = service.listen('en');
      await flush();
      await service.cancel();
      recognizer.listenGate!.complete();
      expect(await pending, isFalse);
    });
  });

  group('stop and cancel', () {
    test('stop ends listening and keeps the final result', () async {
      await service.listen('en');
      await service.stop();
      expect(recognizer.stopCalls, 1);
      expect(service.state, const SpeechInputIdle());

      recognizer.emitResult('done', isFinal: true);
      await flush();
      expect(results, [const SpeechInputResult('done', isFinal: true)]);
    });

    test('cancel drops later results', () async {
      await service.listen('en');
      await service.cancel();
      expect(recognizer.cancelCalls, 1);
      expect(service.state, const SpeechInputIdle());

      recognizer.emitResult('ignored', isFinal: true);
      await flush();
      expect(results, isEmpty);
    });

    test('are no-ops when idle', () async {
      await service.stop();
      await service.cancel();
      expect(recognizer.stopCalls, 0);
      expect(recognizer.cancelCalls, 0);
      expect(states, isEmpty);
    });

    test('swallow recogniser failures', () async {
      recognizer.stopError = Exception('stop');
      await service.listen('en');
      await service.stop();
      await service.listen('en');
      await service.cancel();
      expect(service.state, const SpeechInputIdle());
    });
  });

  group('errors', () {
    test('no match is a transient error owned by the session', () async {
      final owner = Object();
      await service.listen('en', owner: owner);
      recognizer.emitError('error_no_match');
      await flush();
      expect(
        service.state,
        SpeechInputError(
          'error_no_match',
          permanent: false,
          failure: SpeechInputFailure.noMatch,
          owner: owner,
        ),
      );
      expect(service.isListening, isFalse);
    });

    test('permission errors are permanent', () async {
      await service.listen('en');
      recognizer.emitError('error_permission', permanent: false);
      await flush();
      expect(
        service.state,
        const SpeechInputError(
          'error_permission',
          permanent: true,
          failure: SpeechInputFailure.permissionDenied,
        ),
      );
    });

    test('cancellation echoes return to idle silently', () async {
      await service.listen('en');
      recognizer.emitError('error_client');
      await flush();
      expect(service.state, const SpeechInputIdle());
      expect(states.whereType<SpeechInputError>(), isEmpty);

      states.clear();
      recognizer.emitError('aborted');
      await flush();
      expect(states, isEmpty);
    });

    test('classifySpeechError maps platform codes', () {
      const table = {
        'error_permission': SpeechInputFailure.permissionDenied,
        'error_speech_recognizer_request_not_authorized':
            SpeechInputFailure.permissionDenied,
        'not-allowed': SpeechInputFailure.permissionDenied,
        'service-not-allowed': SpeechInputFailure.permissionDenied,
        'error_language_not_supported': SpeechInputFailure.languageUnavailable,
        'error_language_unavailable': SpeechInputFailure.languageUnavailable,
        'error_assets_not_installed': SpeechInputFailure.languageUnavailable,
        'language-not-supported': SpeechInputFailure.languageUnavailable,
        'error_speech_recognizer_disabled':
            SpeechInputFailure.recognizerUnavailable,
        'speech_not_supported': SpeechInputFailure.recognizerUnavailable,
        'error_audio_error': SpeechInputFailure.audio,
        'audio-capture': SpeechInputFailure.audio,
        'error_no_match': SpeechInputFailure.noMatch,
        'error_speech_timeout': SpeechInputFailure.noMatch,
        'no-speech': SpeechInputFailure.noMatch,
        'error_network': SpeechInputFailure.network,
        'error_server_disconnected': SpeechInputFailure.network,
        'network': SpeechInputFailure.network,
        'error_busy': SpeechInputFailure.busy,
        'error_retry': SpeechInputFailure.busy,
        'error_unknown (7)': SpeechInputFailure.unknown,
        'something new': SpeechInputFailure.unknown,
        ' ERROR_NO_MATCH ': SpeechInputFailure.noMatch,
      };
      table.forEach((code, failure) {
        expect(classifySpeechError(code), failure, reason: code);
      });
      for (final code in [
        'error_client',
        'error_request_cancelled',
        'aborted',
      ]) {
        expect(classifySpeechError(code), isNull, reason: code);
      }
    });

    test('only listening and error states have owners', () {
      final owner = Object();
      expect(const SpeechInputIdle().isOwnedBy(owner), isFalse);
      expect(const SpeechInputIdle().isOwnedBy(null), isFalse);
      expect(const SpeechInputUnavailable().isListening, isFalse);
      expect(SpeechInputListening(owner: owner).isOwnedBy(owner), isTrue);
      expect(
        SpeechInputError('x', permanent: false, owner: owner).isOwnedBy(owner),
        isTrue,
      );
    });

    test('isPermanent marks blocking failures', () {
      expect(
        SpeechInputFailure.values.where((failure) => failure.isPermanent),
        [
          SpeechInputFailure.permissionDenied,
          SpeechInputFailure.languageUnavailable,
          SpeechInputFailure.recognizerUnavailable,
          SpeechInputFailure.audio,
          SpeechInputFailure.offlineModelMissing,
          SpeechInputFailure.offlineUnavailable,
        ],
      );
    });
  });

  group('prefer on-device', () {
    test('defaults to false and is loaded from the store', () async {
      store.values[SpeechInputService.preferOnDeviceKey] = 'true';
      expect(service.preferOnDevice.value, isFalse);
      await service.loadSettings();
      expect(service.preferOnDevice.value, isTrue);
    });

    test('is forgotten until loaded again', () async {
      await service.setPreferOnDevice(value: true);
      store.values.remove(SpeechInputService.preferOnDeviceKey);

      service.forgetSettings();

      expect(service.preferOnDevice.value, isFalse);
      store.values[SpeechInputService.preferOnDeviceKey] = 'true';
      await service.loadSettings();
      expect(service.preferOnDevice.value, isTrue);
    });

    test('is persisted', () async {
      await service.setPreferOnDevice(value: true);
      expect(store.values[SpeechInputService.preferOnDeviceKey], 'true');
      expect(service.preferOnDevice.value, isTrue);
      await service.setPreferOnDevice(value: false);
      expect(store.values[SpeechInputService.preferOnDeviceKey], 'false');
    });

    test('is applied to sessions unless overridden', () async {
      store.values[SpeechInputService.preferOnDeviceKey] = 'true';
      await service.listen('en');
      expect(recognizer.lastRequest.onDevice, isTrue);
      await service.listen('en', preferOnDevice: false);
      expect(recognizer.lastRequest.onDevice, isFalse);
    });

    test('is ignored where on-device recognition is unsupported', () async {
      service = build(onDeviceSupported: false);
      await service.listen('en', preferOnDevice: true);
      expect(recognizer.lastRequest.onDevice, isFalse);
    });

    test('falls back to false when the store fails', () async {
      service = build(keyValueStore: _ThrowingStore());
      await service.loadSettings();
      expect(service.preferOnDevice.value, isFalse);
      await expectLater(
        service.setPreferOnDevice(value: true),
        throwsStateError,
      );
    });
  });

  group('dispose', () {
    test('cancels the session and closes the streams', () async {
      await service.listen('en');
      final statesDone = expectLater(
        service.states,
        emitsInOrder(<Object>[const SpeechInputIdle(), emitsDone]),
      );
      final resultsDone = expectLater(service.results, emitsDone);
      await service.dispose();
      await statesDone;
      await resultsDone;
      expect(recognizer.cancelCalls, 1);
      expect(await service.listen('en'), isFalse);
      expect(await service.initialize(), isFalse);
      await service.dispose();
    });

    test('ignores late initialisation and settings results', () async {
      recognizer.initGate = Completer<void>();
      final pending = service.initialize();
      final settings = service.loadSettings();
      await service.dispose();
      recognizer.initGate!.complete();
      expect(await pending, isFalse);
      await settings;
    });

    test('ignores late recogniser callbacks', () async {
      await service.listen('en');
      await service.stop();
      await service.dispose();
      recognizer
        ..emitResult('late', isFinal: true)
        ..emitError('error_no_match');
      expect(results, isEmpty);
    });
  });
}
