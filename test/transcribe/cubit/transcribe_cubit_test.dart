import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

class _FakeHistoryEntry extends Fake implements HistoryEntry;

void main() {
  late MockTranslationRepository repository;
  late MockOfflineSpeech offline;
  late MockSpeechInputService speechInput;
  late MockHistoryCubit history;
  late FakeTranscriber transcriber;
  late FakeScreenAwake awake;
  late TranslationEngine? engine;
  late List<TranslationEngine> engines;
  late List<TranslationRequest> requests;
  late Map<String, StreamController<TranslationResult>> translations;
  late DateTime now;
  final modes = <TranscribeMode>[];

  setUpAll(() {
    registerFallbackValue(deepl);
    registerFallbackValue(
      const TranslationRequest(text: '', source: english, target: german),
    );
    registerFallbackValue(_FakeHistoryEntry());
  });

  setUp(() {
    repository = MockTranslationRepository();
    offline = MockOfflineSpeech();
    speechInput = MockSpeechInputService();
    history = MockHistoryCubit();
    transcriber = FakeTranscriber();
    awake = FakeScreenAwake();
    engine = deepl;
    engines = [deepl, offlineEngine];
    requests = [];
    translations = {};
    now = DateTime(2026, 10, 22, 9);
    modes.clear();
    when(() => repository.privacyMode).thenReturn(PrivacyMode.online);
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      return (translations[request.text] =
              StreamController<TranslationResult>())
          .stream;
    });
    when(() => offline.isAvailable).thenReturn(true);
    when(offline.isReady).thenAnswer((_) async => true);
    when(() => offline.vadModel).thenReturn(null);
    when(speechInput.cancel).thenAnswer((_) async {});
    when(() => speechInput.isPlatformSupported).thenReturn(true);
    when(() => history.state).thenReturn(const HistoryState());
    when(() => history.add(any())).thenAnswer((_) async {});
  });

  TranscribeCubit build({
    bool withOffline = true,
    bool isWeb = false,
    UsageTracker? usage,
  }) => TranscribeCubit(
    repository: repository,
    engine: () => engine,
    engines: () => engines,
    options: () => const TranslationOptions(),
    source: english,
    target: german,
    offline: withOffline ? offline : null,
    speechInput: speechInput,
    history: history,
    usageTracker: usage,
    screenAwake: awake,
    isWeb: isWeb,
    transcriber: (mode) {
      modes.add(mode);
      return transcriber;
    },
    clock: () => now,
  );

  /// A loaded cubit that is listening.
  Future<TranscribeCubit> listening() async {
    final cubit = build();
    await cubit.load();
    await cubit.start();
    transcriber.emit(const TranscriberListening());
    await settle();
    return cubit;
  }

  void answer(String text, String translation, {bool close = true}) {
    final controller = translations[text]!
      ..add(
        TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: translation,
        ),
      );
    if (close) unawaited(controller.close());
  }

  group('load', () {
    test('Whisper with a model', () async {
      final cubit = build();
      expect(cubit.state.status, TranscribeStatus.loading);
      await cubit.load();
      expect(cubit.state.mode, TranscribeMode.whisper);
      expect(cubit.state.status, TranscribeStatus.idle);
      expect(cubit.state.voiceDetectionMissing, isFalse);
      await cubit.close();
    });

    test('says when speech detection is missing', () async {
      when(() => offline.vadModel).thenReturn(
        WhisperCatalogModel(
          id: 'silero-vad',
          name: 'ggml-silero-v6.2.0.bin',
          url: Uri.parse('https://models.example/vad.bin'),
          size: 10,
          sha1: 'a' * 40,
        ),
      );
      when(offline.isVadReady).thenAnswer((_) async => false);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.voiceDetectionMissing, isTrue);
      await cubit.close();
    });

    test('needs a model without one (or when it cannot tell)', () async {
      when(offline.isReady).thenAnswer((_) async => false);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.mode, TranscribeMode.needsModel);
      expect(cubit.state.mode.canListen, isFalse);
      when(offline.isReady).thenThrow(Exception('disk'));
      await cubit.load();
      expect(cubit.state.mode, TranscribeMode.needsModel);
      // Not listening without a mode that can.
      await cubit.start();
      expect(cubit.state.status, TranscribeStatus.idle);
      await cubit.close();
    });

    test('the browser recogniser on the web, never in Offline only', () async {
      final cubit = build(withOffline: false, isWeb: true);
      await cubit.load();
      expect(cubit.state.mode, TranscribeMode.system);
      when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineOnly);
      await cubit.load();
      expect(cubit.state.mode, TranscribeMode.offlineOnly);
      await cubit.close();
    });

    test('unavailable elsewhere', () async {
      when(() => offline.isAvailable).thenReturn(false);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.mode, TranscribeMode.unavailable);
      await cubit.close();
    });
  });

  group('listening', () {
    test('adds a paragraph per phrase and keeps the screen on', () async {
      final cubit = await listening();
      expect(modes, [TranscribeMode.whisper]);
      expect(transcriber.languages, ['en']);
      verify(speechInput.cancel).called(1);
      expect(cubit.state.status, TranscribeStatus.listening);
      expect(awake.calls, [true]);

      transcriber
        ..emit(const TranscriberLevel(0.7, heardSpeech: true))
        ..emit(const TranscriberPending(1))
        ..emit(const TranscriberPartial('Wel'));
      await settle();
      expect(cubit.state.level, 0.7);
      expect(cubit.state.heardSpeech, isTrue);
      expect(cubit.state.pending, 1);
      expect(cubit.state.partial, 'Wel');

      transcriber
        ..heard('Welcome.', start: 1, end: 3, language: 'en')
        ..heard('', start: 4, end: 5)
        ..heard('', start: 6, end: 9, status: PhraseStatus.skipped);
      await settle();
      expect(cubit.state.entries.map((e) => e.id), [0, 1]);
      expect(cubit.state.entries.first.text, 'Welcome.');
      expect(cubit.state.entries.first.translationStatus, isNull);
      expect(cubit.state.entries.last.status, PhraseStatus.skipped);
      expect(cubit.state.partial, isEmpty);
      expect(cubit.state.hasTranscript, isTrue);
      // Nothing is translated while translation is off.
      verifyNever(() => repository.translate(any(), any()));
      await cubit.close();
      expect(transcriber.cancels, 1);
      expect(awake.calls, [true, false]);
    });

    test('pause and resume continue the time line', () async {
      final cubit = await listening();
      transcriber.heard('One.', start: 1, end: 2);
      await settle();
      now = now.add(const Duration(seconds: 10));
      await cubit.pause();
      await settle();
      expect(cubit.state.status, TranscribeStatus.paused);
      expect(cubit.state.pauseReason, TranscribePauseReason.user);
      expect(transcriber.stops, 1);
      expect(awake.calls, [true, false]);
      // Changing the language is fine while paused.
      cubit.setSource(french);
      expect(cubit.state.source, french);

      await cubit.start();
      transcriber
        ..emit(const TranscriberListening())
        ..heard('Two.', start: 1, end: 2);
      await settle();
      expect(transcriber.languages.last, 'fr');
      expect(cubit.state.entries.last.start, const Duration(seconds: 11));
      expect(cubit.state.entries.last.end, const Duration(seconds: 12));

      await cubit.stop();
      await settle();
      expect(cubit.state.status, TranscribeStatus.idle);
      // Stopping twice does nothing.
      await cubit.stop();
      await cubit.close();
    });

    test('resuming waits for the last phrases of the previous '
        'recording', () async {
      final cubit = await listening();
      transcriber.stopGate = Completer();
      unawaited(cubit.pause());
      await settle();
      final resumed = cubit.start();
      await settle();
      expect(cubit.state.status, TranscribeStatus.starting);
      expect(transcriber.languages, hasLength(1));
      transcriber.stopGate!.complete();
      await resumed;
      expect(transcriber.languages, hasLength(2));
      await cubit.close();
    });

    test('a detected language is used and auto passes none', () async {
      final cubit = build();
      await cubit.load();
      cubit.setSource(Language.auto);
      await cubit.start();
      expect(transcriber.languages, [null]);
      // Not while listening.
      cubit.setSource(french);
      expect(cubit.state.source, Language.auto);
      await cubit.close();
    });

    test('a failure ends listening and is reported once', () async {
      final cubit = await listening();
      transcriber.emit(
        const TranscriberFailed(SpeechInputFailure.permissionDenied),
      );
      await settle();
      expect(cubit.state.status, TranscribeStatus.idle);
      expect(cubit.state.failure, SpeechInputFailure.permissionDenied);
      expect(cubit.state.failures, 1);
      expect(awake.calls, [true, false]);
      await cubit.close();
    });

    test('going to the background pauses', () async {
      final cubit = await listening();
      await cubit.onHidden();
      await settle();
      expect(cubit.state.status, TranscribeStatus.paused);
      expect(cubit.state.pauseReason, TranscribePauseReason.background);
      // Pausing when not listening does nothing.
      await cubit.pause();
      expect(transcriber.stops, 1);
      await cubit.close();
    });

    test('a recording that ends by itself is idle', () async {
      final cubit = await listening();
      await transcriber.controller!.close();
      await settle();
      expect(cubit.state.status, TranscribeStatus.idle);
      await cubit.close();
    });

    test('clear empties the transcript, not while listening', () async {
      final cubit = await listening();
      transcriber.heard('One.', start: 1, end: 2);
      await settle();
      cubit.clear();
      expect(cubit.state.entries, hasLength(1));
      await cubit.stop();
      await settle();
      cubit.clear();
      expect(cubit.state.entries, isEmpty);
      await cubit.close();
    });
  });

  group('translation', () {
    test('translates each phrase in order once turned on', () async {
      final cubit = await listening();
      transcriber.heard('Hello.', start: 0, end: 1, language: 'en');
      await settle();
      cubit.setTranslate(enabled: true);
      transcriber.heard('Bye.', start: 2, end: 3);
      await settle();
      expect(requests.map((r) => r.text), ['Hello.']);
      expect(
        cubit.state.entries.map((e) => e.translationStatus),
        everyElement(TranscriptTranslationStatus.translating),
      );
      answer('Hello.', 'Hallo', close: false);
      await settle();
      expect(cubit.state.entries.first.translation, 'Hallo');
      unawaited(translations['Hello.']!.close());
      await settle();
      expect(
        cubit.state.entries.first.translationStatus,
        TranscriptTranslationStatus.done,
      );
      expect(cubit.state.entries.first.engineName, 'DeepL');
      expect(requests.map((r) => r.text), ['Hello.', 'Bye.']);
      expect(requests.first.target, german);
      expect(requests.first.source, english);
      answer('Bye.', 'Tschüss');
      await settle();
      expect(cubit.state.entries.last.translation, 'Tschüss');
      await cubit.close();
    });

    test('turning it off stops translating; on again picks up', () async {
      final cubit = await listening();
      transcriber
        ..heard('A.', start: 0, end: 1)
        ..heard('B.', start: 1, end: 2);
      await settle();
      cubit
        ..setTranslate(enabled: true)
        ..setTranslate(enabled: true);
      await settle();
      cubit.setTranslate(enabled: false);
      await settle();
      expect(
        cubit.state.entries.map((e) => e.translationStatus),
        everyElement(isNull),
      );
      expect(requests, hasLength(1));
      cubit.setTranslate(enabled: true);
      await settle();
      expect(requests.map((r) => r.text), ['A.', 'A.']);
      await cubit.close();
    });

    test('a new target translates everything again', () async {
      final cubit = await listening();
      transcriber.heard('A.', start: 0, end: 1);
      await settle();
      cubit.setTranslate(enabled: true);
      await settle();
      answer('A.', 'Ah');
      await settle();
      cubit
        ..setTarget(german)
        ..setTarget(Language.auto)
        ..setTarget(french);
      await settle();
      expect(cubit.state.target, french);
      expect(requests.last.target, french);
      expect(cubit.state.entries.single.translation, isEmpty);
      await cubit.close();
    });

    test('consent is waited for, then retried', () async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example'),
        engineId: 'mozhi:deepl',
      );
      final cubit = await listening();
      transcriber.heard('A.', start: 0, end: 1);
      await settle();
      cubit.setTranslate(enabled: true);
      await settle();
      translations['A.']!.addError(consent);
      await settle();
      expect(cubit.state.awaitingConsent.single.id, 0);
      cubit.retryTranslations();
      await settle();
      expect(requests, hasLength(2));
      answer('A.', 'Ah');
      await settle();
      expect(cubit.state.awaitingConsent, isEmpty);
      expect(cubit.state.entries.single.isTranslated, isTrue);
      await cubit.close();
    });

    test('without an engine the translation fails', () async {
      engine = null;
      engines = [];
      final cubit = await listening();
      cubit.setTranslate(enabled: true);
      transcriber.heard('A.', start: 0, end: 1);
      await settle();
      expect(
        cubit.state.entries.single.translationError,
        isA<TranscribeNoEngineException>(),
      );
      expect(const TranscribeNoEngineException().toString(), isNotEmpty);
      // Retrying with translation off does nothing.
      cubit
        ..setTranslate(enabled: false)
        ..retryTranslations();
      await cubit.close();
    });

    test('Offline only translates on the device', () async {
      when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineOnly);
      final cubit = await listening();
      cubit.setTranslate(enabled: true);
      transcriber.heard('A.', start: 0, end: 1, language: 'fr');
      await settle();
      final captured = verify(() => repository.translate(captureAny(), any()))
          .captured;
      expect(captured.single, offlineEngine);
      await cubit.close();
    });

    test('the detected language is the source of "Detect language"', () async {
      final cubit = build();
      await cubit.load();
      cubit
        ..setSource(Language.auto)
        ..setTranslate(enabled: true);
      await cubit.start();
      transcriber.heard('Bonjour.', start: 0, end: 1, language: 'fr');
      await settle();
      expect(requests.single.source.code, 'fr');
      await cubit.close();
    });

    test('answers of bring-your-own-key providers are counted', () async {
      const claude = TranslationEngine(
        id: 'ai:claude',
        kind: EngineKind.ai,
        name: 'Claude',
        providerId: 'claude',
      );
      engine = claude;
      final usage = _MockUsageTracker();
      when(
        () => usage.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => throw Exception('full'));
      final cubit = build(usage: usage);
      await cubit.load();
      await cubit.start();
      cubit.setTranslate(enabled: true);
      transcriber.heard('A.', start: 0, end: 1);
      await settle();
      answer('A.', 'Ah');
      await settle();
      verify(() => usage.recordText('claude', input: 'A.', output: 'Ah'))
          .called(1);
      await cubit.close();
    });
  });

  group('history', () {
    Future<TranscribeCubit> withTranscript() async {
      final cubit = await listening();
      transcriber
        ..heard('One.', start: 0, end: 1, language: 'en')
        ..heard('Two.', start: 1, end: 3, language: 'en');
      await settle();
      return cubit;
    }

    test('saves the transcript as one entry, again as the same', () async {
      final cubit = await withTranscript();
      await cubit.saveToHistory();
      await cubit.saveToHistory();
      final saved = verify(() => history.add(captureAny())).captured;
      final first = saved.first as HistoryEntry;
      expect(first.text, 'One.\n\nTwo.');
      expect(first.translation, isEmpty);
      expect(first.engineId, TranslationEngine.offlineId);
      expect(first.isFavorite, isFalse);
      expect((saved.last as HistoryEntry).id, first.id);
      expect(cubit.state.historyOutcome, TranscribeHistoryOutcome.saved);
      expect(cubit.state.historySaves, 2);
      await cubit.close();
    });

    test('a translated transcript names its engine and language', () async {
      final cubit = await withTranscript();
      cubit
        ..setSource(Language.auto)
        ..setTranslate(enabled: true);
      await settle();
      answer('One.', 'Eins');
      await settle();
      await cubit.saveToHistory();
      final entry =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(entry.engineId, deepl.id);
      expect(entry.translation, 'Eins');
      await cubit.close();
    });

    test('while history is paused it is a favourite', () async {
      when(() => history.state).thenReturn(const HistoryState(incognito: true));
      final cubit = await withTranscript();
      await cubit.saveToHistory();
      final entry =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(entry.isFavorite, isTrue);
      expect(
        cubit.state.historyOutcome,
        TranscribeHistoryOutcome.savedAsFavorite,
      );
      await cubit.close();
    });

    test('a failed save is reported', () async {
      when(() => history.add(any())).thenThrow(Exception('disk'));
      final cubit = await withTranscript();
      final errors = <Object>[];
      final subscription = cubit.stream.listen((_) {}, onError: errors.add);
      await cubit.saveToHistory();
      expect(cubit.state.historyOutcome, TranscribeHistoryOutcome.failed);
      await subscription.cancel();
      await cubit.close();
    });

    test('an empty transcript is not saved', () async {
      final cubit = await listening();
      await cubit.saveToHistory();
      verifyNever(() => history.add(any()));
      await cubit.close();
    });
  });

  group('speech detection download', () {
    test('reports progress and then not missing', () async {
      when(
        () => offline.downloadVoiceDetection(
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenAnswer((invocation) async {
        (invocation.namedArguments[#onProgress] as void Function(double))(0.5);
      });
      final cubit = build();
      final states = <TranscribeState>[];
      final subscription = cubit.stream.listen(states.add);
      await cubit.downloadVoiceDetection();
      await settle();
      expect(states.map((s) => s.voiceDetectionProgress), [0, 0.5, null]);
      expect(cubit.state.voiceDetectionMissing, isFalse);
      expect(cubit.state.voiceDetectionError, isNull);
      await subscription.cancel();
      await cubit.close();
    });

    test('a metered network asks; other failures are reported', () async {
      when(
        () => offline.downloadVoiceDetection(
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenThrow(const VoiceModelMeteredException());
      final cubit = build();
      await cubit.downloadVoiceDetection();
      expect(
        cubit.state.voiceDetectionError?.kind,
        VoiceModelErrorKind.metered,
      );
      expect(cubit.state.voiceDetectionMissing, isTrue);
      when(
        () => offline.downloadVoiceDetection(
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenThrow(const WhisperDownloadException('silero-vad', 'offline'));
      await cubit.downloadVoiceDetection(overMeteredNetwork: true);
      expect(
        cubit.state.voiceDetectionError?.kind,
        VoiceModelErrorKind.network,
      );
      await cubit.close();
    });

    test('nothing to download without Whisper', () async {
      final cubit = build(withOffline: false);
      await cubit.downloadVoiceDetection();
      expect(cubit.state.voiceDetectionProgress, isNull);
      await cubit.close();
    });
  });
}
