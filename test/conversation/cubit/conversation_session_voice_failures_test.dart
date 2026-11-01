import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../voice/helpers/fake_offline_recognizer.dart';
import '../../voice/helpers/fake_speech_recognizer.dart';
import '../helpers.dart';

/// A hands-free conversation over the app's own recogniser and voice input
/// service (only the platform's recognisers are fakes): every way the
/// large microphone can fail to listen ends as [ConversationSessionFailed]
/// with the reason, never as a quiet pause or nothing at all.
void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late PrivacyMode privacy;
  late SpeechInputService service;
  late FakeTimers timers;

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    system = FakeSpeechRecognizer();
    whisper = FakeOfflineRecognizer();
    privacy = PrivacyMode.offlineFirst;
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      offlineAdapter: whisper,
      privacyMode: () => privacy,
      platformSupported: true,
      onDeviceSupported: true,
    );
    timers = FakeTimers();
  });

  tearDown(() async {
    await service.dispose();
    await speaking.close();
  });

  ConversationCubit build() => ConversationCubit(
    repository: repository,
    speech: speech,
    engine: () => deepl,
    languageA: english,
    languageB: spanish,
    autoSpeak: true,
    recognizer: SpeechInputConversationRecognizer(service, timer: timers.call),
    timer: timers.call,
  );

  const starting = ConversationSessionListening(side: ConversationSide.a);
  final listening = starting.copyWith(stage: ConversationListenStage.listening);

  ConversationSessionFailed failed(
    SpeechInputFailure failure, {
    bool offlineSupported = true,
  }) => ConversationSessionFailed(
    next: ConversationSide.a,
    failure: failure,
    offlineSupported: offlineSupported,
  );

  group('the microphone explains why it cannot listen', () {
    blocTest<ConversationCubit, ConversationState>(
      'no speech recognition service and no offline model',
      setUp: () {
        system.initResult = false;
        whisper.ready = false;
      },
      build: build,
      act: (cubit) => cubit.toggleSession(),
      wait: Duration.zero,
      verify: (cubit) {
        expect(
          cubit.state.session,
          failed(SpeechInputFailure.recognizerUnavailable),
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'a recogniser that initialises but never answers',
      setUp: () => whisper.ready = false,
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await settle();
        system.emitError('error_client');
      },
      wait: Duration.zero,
      verify: (cubit) {
        // Not "Nothing heard" after four empty tries.
        expect(
          cubit.state.session,
          failed(SpeechInputFailure.recognizerUnavailable),
        );
        expect(system.requests, hasLength(1));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'a denied microphone',
      setUp: () {
        whisper.ready = false;
        system
          ..initResult = false
          ..permission = false;
      },
      build: build,
      act: (cubit) => cubit.toggleSession(),
      wait: Duration.zero,
      verify: (cubit) {
        expect(
          cubit.state.session,
          failed(SpeechInputFailure.permissionDenied),
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'Offline only without the offline model',
      setUp: () {
        privacy = PrivacyMode.offlineOnly;
        whisper.ready = false;
      },
      build: build,
      act: (cubit) => cubit.toggleSession(),
      wait: Duration.zero,
      verify: (cubit) {
        expect(
          cubit.state.session,
          failed(SpeechInputFailure.offlineModelMissing),
        );
        expect(system.initCalls, 0);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'Whisper chosen without a model',
      setUp: () => whisper.ready = false,
      build: build,
      act: (cubit) async {
        await service.setEngine(VoiceInputEngine.whisper);
        await cubit.toggleSession();
      },
      wait: Duration.zero,
      verify: (cubit) {
        expect(
          cubit.state.session,
          failed(SpeechInputFailure.offlineModelMissing),
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'the session goes from starting straight to the failure',
      setUp: () {
        system.initResult = false;
        whisper.ready = false;
      },
      build: build,
      act: (cubit) => cubit.toggleSession(),
      wait: Duration.zero,
      expect: () => [
        isA<ConversationState>().having(
          (state) => state.session,
          'session',
          starting,
        ),
        isA<ConversationState>().having(
          (state) => state.session,
          'session',
          failed(SpeechInputFailure.recognizerUnavailable),
        ),
      ],
    );
  });

  group('the microphone listens', () {
    blocTest<ConversationCubit, ConversationState>(
      'with the offline model where there is no recognition service',
      setUp: () => system.initResult = false,
      build: build,
      act: (cubit) => cubit.toggleSession(),
      wait: Duration.zero,
      verify: (cubit) {
        expect(cubit.state.session, listening);
        expect(whisper.requests, hasLength(1));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'with the offline model after the recogniser never answered',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await settle();
        system.emitError('error_client');
        await settle();
        await cubit.toggleSession();
      },
      wait: Duration.zero,
      verify: (cubit) {
        expect(cubit.state.session, listening);
        expect(system.requests, hasLength(1));
        expect(whisper.requests, hasLength(1));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'again after a failure once it can (the microphone was allowed)',
      setUp: () {
        system
          ..initResult = false
          ..permission = false;
        whisper.ready = false;
      },
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await settle();
        system
          ..initResult = true
          ..permission = true;
        await service.refreshAvailability();
        await cubit.toggleSession();
      },
      wait: Duration.zero,
      verify: (cubit) {
        expect(cubit.state.session, listening);
        expect(system.requests, hasLength(1));
      },
    );
  });
}
