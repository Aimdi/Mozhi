import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import 'helpers/fake_offline_recognizer.dart';
import 'helpers/fake_speech_recognizer.dart';

/// A platform recogniser that initialises but answers no session
/// (Android 12+ on a de-Googled phone: the system names an on-device
/// recogniser no app provides, so `speech_to_text` initialises, and
/// listening ends at once with `error_client`).
void main() {
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late SpeechInputService service;
  late List<SpeechInputState> states;
  final owner = Object();

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  SpeechInputService build({bool withOffline = true}) {
    final created = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      offlineAdapter: withOffline ? whisper : null,
      privacyMode: () => PrivacyMode.offlineFirst,
      platformSupported: true,
      onDeviceSupported: true,
    );
    created.states.listen(states.add);
    return created;
  }

  setUp(() {
    system = FakeSpeechRecognizer();
    whisper = FakeOfflineRecognizer()..ready = false;
    states = [];
    service = build();
  });

  tearDown(() => service.dispose());

  const unavailable = SpeechInputFailure.recognizerUnavailable;

  test('the code is the one speech_to_text reports', () {
    expect(SpeechInputService.unreachableCode, 'error_client');
  });

  group('error_client before the recogniser heard anything', () {
    test('fails the session as no speech recognition service', () async {
      expect(await service.listen('de', owner: owner), isTrue);
      system.emitError('error_client');
      await flush();
      expect(
        service.state,
        SpeechInputError(
          'error_client',
          permanent: true,
          failure: unavailable,
          owner: owner,
        ),
      );
      expect(service.isListening, isFalse);
    });

    test('later sessions use an installed offline model', () async {
      await service.listen('de', owner: owner);
      system.emitError('error_client');
      await flush();

      whisper.ready = true;
      await service.offlineModelsChanged();
      expect(await service.listen('de', owner: owner), isTrue);
      expect(whisper.requests, hasLength(1));
      expect(system.requests, hasLength(1));
      expect(service.state, isA<SpeechInputListening>());
    });

    test('without a model the system recogniser is tried again', () async {
      await service.listen('de', owner: owner);
      system.emitError('error_client');
      await flush();

      expect(await service.listen('de', owner: owner), isTrue);
      expect(system.requests, hasLength(2));
      system.emitError('error_client');
      await flush();
      expect(
        service.state,
        isA<SpeechInputError>().having(
          (error) => error.failure,
          'failure',
          unavailable,
        ),
      );
    });

    test('is explained without an offline engine too', () async {
      await service.dispose();
      service = build(withOffline: false);
      await service.listen('de', owner: owner);
      system.emitError('error_client');
      await flush();
      expect(
        service.state,
        isA<SpeechInputError>()
            .having((error) => error.failure, 'failure', unavailable)
            .having((error) => error.permanent, 'permanent', isTrue),
      );
    });
  });

  group('error_client stays a cancellation echo', () {
    test('once the session reported a sound level', () async {
      await service.listen('de', owner: owner);
      system
        ..emitLevel(-2)
        ..emitError('error_client');
      await flush();
      expect(service.state, const SpeechInputIdle());
    });

    test(
      'once the recogniser recognised words in an earlier session',
      () async {
        await service.listen('de', owner: owner);
        system.emitResult('Hallo', isFinal: true);
        await flush();
        await service.listen('de', owner: owner);
        system.emitError('error_client');
        await flush();
        expect(service.state, const SpeechInputIdle());
        // The system recogniser stays in use.
        whisper.ready = true;
        await service.listen('de', owner: owner);
        expect(whisper.requests, isEmpty);
      },
    );

    test('after stop and cancel', () async {
      await service.listen('de', owner: owner);
      await service.stop();
      system.emitError('error_client');
      await flush();
      expect(service.state, const SpeechInputIdle());

      await service.listen('de', owner: owner);
      await service.cancel();
      system.emitError('error_client');
      await flush();
      expect(service.state, const SpeechInputIdle());
      expect(states.whereType<SpeechInputError>(), isEmpty);
    });

    test('for other cancellation codes', () async {
      await service.listen('de', owner: owner);
      system.emitError('aborted');
      await flush();
      expect(service.state, const SpeechInputIdle());
    });
  });
}
