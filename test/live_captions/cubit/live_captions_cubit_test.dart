import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/live_captions/cubit/live_captions_cubit.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _FakeHistoryEntry extends Fake implements HistoryEntry;

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example.org'),
  engineId: 'mozhi:deepl',
  source: 'es',
  target: 'en',
);

void main() {
  late FakeCaptionsHost host;
  late FakeCaptionRecognizer recognizer;
  late FakeOverlayControls overlay;
  late MockTranslationRepository repository;
  late MockDeviceConditions conditions;
  late StreamController<DeviceConditionsSnapshot> heat;
  late MockHistoryCubit history;
  late TranslationEngine engine;
  late List<TranslationRequest> requests;

  setUpAll(() {
    registerFallbackValue(deepl);
    registerFallbackValue(
      const TranslationRequest(text: '', source: english, target: german),
    );
    registerFallbackValue(_FakeHistoryEntry());
  });

  setUp(() {
    host = FakeCaptionsHost();
    recognizer = FakeCaptionRecognizer();
    overlay = FakeOverlayControls();
    repository = MockTranslationRepository();
    conditions = MockDeviceConditions();
    heat = StreamController.broadcast();
    history = MockHistoryCubit();
    engine = deepl;
    requests = [];
    when(() => conditions.latest).thenReturn(DeviceConditionsSnapshot.unknown);
    when(() => conditions.changes).thenAnswer((_) => heat.stream);
    when(() => history.state).thenReturn(const HistoryState());
    when(() => history.add(any())).thenAnswer((_) async {});
    // "Hola" -> "[en] Hola".
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      return Stream.value(resultOf('[${request.target.code}] ${request.text}'));
    });
  });

  tearDown(() async {
    await host.dispose();
    await heat.close();
  });

  LiveCaptionsCubit build({
    Language source = Language.auto,
    Language target = english,
    bool withRecognizer = true,
    bool withOverlay = true,
  }) => LiveCaptionsCubit(
    host: host,
    repository: repository,
    engine: () => engine,
    source: source,
    target: target,
    recognizer: withRecognizer ? recognizer : null,
    overlay: withOverlay ? overlay : null,
    conditions: conditions,
    history: history,
    describe: (text) => 'bar:${text.name}',
    clock: () => DateTime(2026, 10, 26, 20),
  );

  /// A cubit that captions (loaded and started).
  Future<LiveCaptionsCubit> running({
    Language source = Language.auto,
    Language target = english,
  }) async {
    final cubit = build(source: source, target: target);
    await cubit.load();
    await cubit.start();
    await settle();
    expect(cubit.state.status, LiveCaptionsStatus.running);
    return cubit;
  }

  group('load', () {
    test('is unsupported without a host that captures', () async {
      host = FakeCaptionsHost(isSupported: false);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.status, LiveCaptionsStatus.unsupported);
      await cubit.close();
    });

    test('needs the speech model without one', () async {
      final none = build(withRecognizer: false);
      await none.load();
      expect(none.state.status, LiveCaptionsStatus.needsModel);
      recognizer.ready = false;
      final missing = build();
      await missing.load();
      expect(missing.state.status, LiveCaptionsStatus.needsModel);
      // Downloaded meanwhile: ready.
      recognizer.ready = true;
      await missing.load();
      expect(missing.state.status, LiveCaptionsStatus.idle);
      await none.close();
      await missing.close();
    });

    test('changes nothing while captions run', () async {
      final cubit = await running();
      recognizer.ready = false;
      await cubit.load();
      expect(cubit.state.status, LiveCaptionsStatus.running);
      await cubit.close();
    });
  });

  group('start', () {
    blocTest<LiveCaptionsCubit, LiveCaptionsState>(
      'does nothing until loaded',
      build: build,
      act: (cubit) => cubit.start(),
      expect: () => <LiveCaptionsState>[],
      verify: (_) => expect(host.starts, 0),
    );

    test('captures, shows "Listening…" and records in the language', () async {
      final cubit = await running(source: spanish);
      expect(host.starts, 1);
      expect(cubit.state.captionBar, isTrue);
      expect(host.bar, const CaptionLine.notice('bar:listening'));
      expect(recognizer.languages, ['es']);
      // Nothing asked: the bar and notifications are allowed.
      expect(overlay.overlayRequests, 0);
      expect(overlay.notificationRequests, 0);
      await cubit.close();
    });

    test('lets Whisper detect the language with "Detect"', () async {
      final cubit = await running();
      expect(recognizer.languages, [null]);
      await cubit.close();
    });

    test('without the bar, the captions are only on the screen', () async {
      host.startResult = const CaptureStarted(captionBar: false);
      final cubit = await running();
      expect(cubit.state.captionBar, isFalse);
      await cubit.close();
    });

    test('asks for notifications once', () async {
      overlay.notificationsAllowed = false;
      final cubit = await running();
      expect(overlay.notificationRequests, 1);
      await cubit.stop();
      overlay.notificationsAllowed = false;
      await cubit.start();
      await settle();
      expect(overlay.notificationRequests, 1);
      await cubit.close();
    });

    for (final (result, notice) in [
      (const CaptureDeclined(), LiveCaptionsNotice.declined),
      (
        const CaptureFailed(CaptureFailure.permission),
        LiveCaptionsNotice.permissionDenied,
      ),
      (
        const CaptureFailed(CaptureFailure.audio),
        LiveCaptionsNotice.startFailed,
      ),
    ]) {
      test('says why when the capture does not start: $result', () async {
        host.startResult = result;
        final cubit = build();
        await cubit.load();
        await cubit.start();
        expect(cubit.state.status, LiveCaptionsStatus.idle);
        expect(cubit.state.notice, notice);
        expect(cubit.state.notices, 1);
        expect(recognizer.recordings, isEmpty);
        await cubit.close();
      });
    }

    test('a failing speech engine stops the capture', () async {
      recognizer.startError = Exception('no model');
      final cubit = build();
      await cubit.load();
      await cubit.start();
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      expect(cubit.state.notice, LiveCaptionsNotice.startFailed);
      expect(host.stops, 1);
      await cubit.close();
    });
  });

  group('the caption bar permission', () {
    setUp(() => overlay.canDrawOverlays = false);

    test('is explained first; "Open the setting" asks, then starts', () async {
      final cubit = build();
      await cubit.load();
      await cubit.start();
      expect(cubit.state.overlayPrompt, isTrue);
      expect(host.starts, 0);
      await cubit.allowCaptionBar();
      await settle();
      expect(cubit.state.overlayPrompt, isFalse);
      expect(overlay.overlayRequests, 1);
      expect(cubit.state.status, LiveCaptionsStatus.running);
      // Asked once only.
      await cubit.stop();
      overlay.canDrawOverlays = false;
      await cubit.start();
      await settle();
      expect(cubit.state.overlayPrompt, isFalse);
      expect(host.starts, 2);
      await cubit.close();
    });

    test('"Only on this screen" starts without asking', () async {
      final cubit = build();
      await cubit.load();
      await cubit.start();
      await cubit.skipCaptionBar();
      await settle();
      expect(overlay.overlayRequests, 0);
      expect(cubit.state.status, LiveCaptionsStatus.running);
      await cubit.close();
    });

    test('dismissed, nothing starts', () async {
      final cubit = build();
      await cubit.load();
      await cubit.start();
      cubit.dismissCaptionBarPrompt();
      expect(cubit.state.overlayPrompt, isFalse);
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      // Without a prompt the answers do nothing.
      await cubit.allowCaptionBar();
      await cubit.skipCaptionBar();
      cubit.dismissCaptionBarPrompt();
      expect(host.starts, 0);
      await cubit.close();
    });

    test('is not asked without the controls', () async {
      final cubit = build(withOverlay: false);
      await cubit.load();
      await cubit.start();
      await settle();
      expect(cubit.state.status, LiveCaptionsStatus.running);
      await cubit.close();
    });
  });

  group('audio to captions', () {
    test('the audio goes to the recording, phrases to the bar', () async {
      final cubit = await running();
      host.sendAudio(block());
      await settle();
      expect(recognizer.recording.added, hasLength(1));
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      final entry = cubit.state.entries.single;
      expect(entry.text, 'Hola');
      expect(entry.language, 'es');
      expect(entry.translation, '[en] Hola');
      expect(entry.translationStatus, TranscriptTranslationStatus.done);
      expect(entry.engineId, deepl.id);
      expect(cubit.state.detectedLanguage, 'es');
      expect(requests.single.source.code, 'es');
      expect(requests.single.target, english);
      // The original while translating, then both.
      expect(host.shown, [
        const CaptionLine.notice('bar:listening'),
        const CaptionLine(translation: 'Hola', isFinal: false),
        const CaptionLine(original: 'Hola', translation: '[en] Hola'),
      ]);
      await cubit.close();
    });

    test('a chosen language is the source of every phrase', () async {
      final cubit = await running(source: spanish);
      recognizer.recording.phrase('Hola', language: 'pt');
      await settle();
      expect(requests.single.source, spanish);
      await cubit.close();
    });

    test('a phrase in the target language is shown as it is', () async {
      final cubit = await running();
      recognizer.recording.phrase('Hello there', language: 'en');
      await settle();
      expect(requests, isEmpty);
      final entry = cubit.state.entries.single;
      expect(entry.translation, 'Hello there');
      expect(entry.isTranslated, isTrue);
      // No original under the same text.
      expect(host.bar, const CaptionLine(translation: 'Hello there'));
      await cubit.close();
    });

    test(
      'without "Show the original" the bar has the translation only',
      () async {
        final cubit = await running();
        cubit.setShowOriginal(enabled: false);
        expect(cubit.state.showOriginal, isFalse);
        // Unchanged: nothing new.
        cubit.setShowOriginal(enabled: false);
        recognizer.recording.phrase('Hola', language: 'es');
        await settle();
        expect(host.bar, const CaptionLine(translation: '[en] Hola'));
        await cubit.close();
      },
    );

    test('noise without words is left out; skipped phrases stay', () async {
      final cubit = await running();
      recognizer.recording
        ..pending = 2
        ..phrase('')
        ..pending = 0
        ..phrase('', status: PhraseStatus.skipped)
        ..phrase('', status: PhraseStatus.failed);
      await settle();
      expect(cubit.state.entries.map((entry) => entry.status), [
        PhraseStatus.skipped,
        PhraseStatus.failed,
      ]);
      expect(cubit.state.entries.first.translationStatus, isNull);
      expect(requests, isEmpty);
      await cubit.close();
    });

    test('reports phrases waiting for the engine', () async {
      final cubit = await running();
      recognizer.recording.pending = 2;
      host.sendAudio(block());
      await settle();
      expect(cubit.state.pending, 2);
      recognizer.recording.pending = 1;
      recognizer.recording.phrase('');
      await settle();
      expect(cubit.state.pending, 1);
      await cubit.close();
    });

    test('a newer phrase keeps the bar', () async {
      final gate = StreamController<TranslationResult>();
      when(() => repository.translate(any(), any())).thenAnswer((invocation) {
        final request = invocation.positionalArguments[1] as TranslationRequest;
        if (request.text == 'Uno') return gate.stream;
        return Stream.value(resultOf('[en] ${request.text}'));
      });
      final cubit = await running();
      recognizer.recording
        ..phrase('Uno', language: 'es')
        ..phrase('Dos', language: 'es');
      await settle();
      gate
        ..add(resultOf('One'))
        ..add(resultOf('One.'));
      await gate.close();
      await settle();
      // "One." is late: the bar shows "Dos" as it arrives.
      expect(host.bar.translation, '[en] Dos');
      expect(cubit.state.entries.first.translation, 'One.');
      await cubit.close();
    });

    test('keeps up: an old phrase waiting behind three is skipped', () async {
      final first = StreamController<TranslationResult>();
      when(() => repository.translate(any(), any())).thenAnswer((invocation) {
        final request = invocation.positionalArguments[1] as TranslationRequest;
        requests.add(request);
        if (request.text == '0') return first.stream;
        return Stream.value(resultOf('t${request.text}'));
      });
      final cubit = await running(source: spanish);
      // "0" is being translated while four more arrive.
      recognizer.recording.phrase('0');
      await settle();
      for (var i = 1; i < 5; i++) {
        recognizer.recording.phrase('$i', index: i);
      }
      await settle();
      await first.close();
      await settle();
      final entries = cubit.state.entries;
      expect(entries[1].translationError, isA<LiveCaptionsBehindException>());
      expect(entries[1].translationStatus, TranscriptTranslationStatus.failed);
      expect(requests.map((r) => r.text), ['0', '2', '3', '4']);
      // Not retried: it is old news.
      cubit.retryTranslations();
      await settle();
      expect(requests, hasLength(4));
      await cubit.close();
    });

    test(
      'of phrases that arrive at once, the last three are translated',
      () async {
        final cubit = await running(source: spanish);
        for (var i = 0; i < 5; i++) {
          recognizer.recording.phrase('$i', index: i);
        }
        await settle();
        expect(requests.map((r) => r.text), ['2', '3', '4']);
        expect(
          cubit.state.entries.take(2).map((entry) => entry.translationError),
          everyElement(isA<LiveCaptionsBehindException>()),
        );
        await cubit.close();
      },
    );

    test('keeps at most the last phrases in memory', () async {
      final cubit = await running(target: spanish, source: spanish);
      for (var i = 0; i < LiveCaptionsCubit.maxEntries + 5; i++) {
        recognizer.recording.phrase('$i');
      }
      await settle();
      expect(cubit.state.entries, hasLength(LiveCaptionsCubit.maxEntries));
      expect(cubit.state.entries.first.text, '5');
      await cubit.close();
    });
  });

  group('translation failures', () {
    test('a failed translation can be retried', () async {
      var fail = true;
      when(() => repository.translate(any(), any())).thenAnswer((_) {
        if (fail) return Stream.error(StateError('offline'));
        return Stream.value(resultOf('Hello'));
      });
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      final failed = cubit.state.entries.single;
      expect(failed.translationStatus, TranscriptTranslationStatus.failed);
      expect(failed.translationError, isA<StateError>());
      expect(cubit.state.consent, isNull);
      fail = false;
      cubit.retryTranslations();
      await settle();
      expect(cubit.state.entries.single.translation, 'Hello');
      expect(cubit.state.entries.single.isTranslated, isTrue);
      await cubit.close();
    });

    test('a translation that needs consent waits for it', () async {
      var allowed = false;
      when(() => repository.translate(any(), any())).thenAnswer((_) {
        if (!allowed) return Stream.error(_consent);
        return Stream.value(resultOf('Hello'));
      });
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      expect(cubit.state.consent, _consent);
      cubit.dismissConsent();
      expect(cubit.state.consent, isNull);
      cubit.dismissConsent();
      allowed = true;
      cubit.retryTranslations();
      await settle();
      expect(cubit.state.entries.single.translation, 'Hello');
      // Nothing failed: nothing more to retry.
      cubit.retryTranslations();
      await settle();
      verify(() => repository.translate(any(), any())).called(2);
      await cubit.close();
    });

    test('the engine is the live engine of the moment', () async {
      final cubit = await running();
      engine = offlineEngine;
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      verify(() => repository.translate(offlineEngine, any())).called(1);
      await cubit.close();
    });
  });

  group('silence', () {
    test('after 20 s, a hint that the app may not allow capture', () async {
      final cubit = await running();
      for (var i = 0; i < 199; i++) {
        host.sendAudio(block(0));
      }
      await settle();
      expect(cubit.state.silenceHint, isFalse);
      host.sendAudio(block(0));
      await settle();
      expect(cubit.state.silenceHint, isTrue);
      expect(host.bar, const CaptionLine.notice('bar:silence'));
      // Sound again: the hint goes, "Listening…" is back.
      host.sendAudio(block());
      await settle();
      expect(cubit.state.silenceHint, isFalse);
      expect(host.bar, const CaptionLine.notice('bar:listening'));
      await cubit.close();
    });

    test('the last caption comes back after the hint', () async {
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      for (var i = 0; i < 200; i++) {
        host.sendAudio(block(0.00001));
      }
      await settle();
      expect(cubit.state.silenceHint, isTrue);
      host.sendAudio(block());
      await settle();
      expect(
        host.bar,
        const CaptionLine(original: 'Hola', translation: '[en] Hola'),
      );
      await cubit.close();
    });

    test('quiet sound restarts the count', () async {
      final cubit = await running();
      for (var i = 0; i < 150; i++) {
        host.sendAudio(block(0));
      }
      host.sendAudio(block(0.01));
      for (var i = 0; i < 150; i++) {
        host.sendAudio(block(0));
      }
      await settle();
      expect(cubit.state.silenceHint, isFalse);
      await cubit.close();
    });
  });

  group('stop and start', () {
    test('stop ends the capture; the last phrase is still heard', () async {
      final cubit = await running();
      final recording = recognizer.recording;
      await cubit.stop();
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      expect(host.stops, 1);
      expect(recording.finished, isTrue);
      recording.phrase('Adiós', language: 'es');
      await settle();
      expect(cubit.state.entries.single.translation, '[en] Adiós');
      // Not shown on a bar that is gone.
      expect(
        host.shown.where((line) => line.translation == '[en] Adiós'),
        isEmpty,
      );
      // Audio after the stop is ignored.
      host.sendAudio(block());
      await settle();
      expect(recording.added, isEmpty);
      await cubit.stop();
      expect(host.stops, 1);
      await cubit.close();
    });

    test('a new start continues the transcript and its time line', () async {
      final cubit = await running();
      for (var i = 0; i < 30; i++) {
        host.sendAudio(block());
      }
      await settle();
      await cubit.stop();
      await cubit.start();
      await settle();
      expect(recognizer.recordings, hasLength(2));
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      // 3 s of the first recording come first.
      expect(cubit.state.entries.single.start, const Duration(seconds: 3));
      await cubit.close();
    });

    test('stopped while starting, the capture is stopped again', () async {
      final gate = host.startGate = Completer<void>();
      final cubit = build();
      await cubit.load();
      unawaited(cubit.start());
      await settle();
      expect(cubit.state.status, LiveCaptionsStatus.starting);
      expect(cubit.state.isActive, isTrue);
      await cubit.stop();
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      gate.complete();
      await settle();
      expect(host.stops, 2);
      expect(recognizer.recordings, isEmpty);
      await cubit.close();
    });

    test('stopped while the engine starts, the recording is dropped', () async {
      final gate = recognizer.startGate = Completer<void>();
      final cubit = build();
      await cubit.load();
      unawaited(cubit.start());
      await settle();
      expect(recognizer.languages, hasLength(1));
      await cubit.stop();
      gate.complete();
      await settle();
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      expect(recognizer.recording.cancelled, isTrue);
      expect(host.stops, 1);
      await cubit.close();
    });

    test('the languages', () async {
      final cubit = build();
      await cubit.load();
      cubit
        ..setSource(spanish)
        ..setTarget(german)
        // Ignored: no auto or custom target, the same one.
        ..setTarget(Language.auto)
        ..setTarget(german)
        ..setSource(const Language(code: 'x', name: 'Pirate', isCustom: true));
      expect(cubit.state.source, spanish);
      expect(cubit.state.target, german);
      await cubit.start();
      await settle();
      // While running only the target changes.
      cubit
        ..setSource(english)
        ..setTarget(english);
      expect(cubit.state.source, spanish);
      expect(cubit.state.target, english);
      await cubit.close();
    });
  });

  group('outside the app', () {
    test('Stop on the bar or in the notification ends the captions', () async {
      final cubit = await running();
      host.sendEvent(CaptionBarEvent.stopTapped);
      await settle();
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      expect(cubit.state.notice, isNull);
      expect(recognizer.recording.finished, isTrue);
      // The platform stopped already.
      expect(host.stops, 0);
      // Repeated: nothing more.
      host.sendEvent(CaptionBarEvent.stopTapped);
      await settle();
      await cubit.close();
    });

    test('a capture that ends by itself says so', () async {
      final cubit = await running();
      host.sendEvent(CaptionBarEvent.captureEnded);
      await settle();
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      expect(cubit.state.notice, LiveCaptionsNotice.captureEnded);
      host.sendEvent(CaptionBarEvent.captureEnded);
      await settle();
      expect(cubit.state.notices, 1);
      await cubit.close();
    });

    test('Open changes nothing', () async {
      final cubit = await running();
      final before = cubit.state;
      host.sendEvent(CaptionBarEvent.openTapped);
      await settle();
      expect(cubit.state, before);
      await cubit.close();
    });

    test('in the background the captions go on', () async {
      // Nothing in the cubit reacts to the app's lifecycle: audio keeps
      // arriving and is captioned.
      final cubit = await running();
      host.sendAudio(block());
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      expect(cubit.state.isRunning, isTrue);
      expect(cubit.state.entries, hasLength(1));
      await cubit.close();
    });

    test('locked, nothing is heard until unlocked', () async {
      final cubit = await running();
      host.sendEvent(CaptionBarEvent.deviceLocked);
      await settle();
      expect(cubit.state.pause, LiveCaptionsPause.locked);
      host.sendAudio(block());
      await settle();
      expect(recognizer.recording.added, isEmpty);
      host.sendEvent(CaptionBarEvent.deviceUnlocked);
      await settle();
      expect(cubit.state.pause, isNull);
      host.sendAudio(block());
      await settle();
      expect(recognizer.recording.added, hasLength(1));
      await cubit.close();
    });

    test('lock and unlock change nothing while stopped', () async {
      final cubit = build();
      await cubit.load();
      host
        ..sendEvent(CaptionBarEvent.deviceLocked)
        ..sendEvent(CaptionBarEvent.deviceUnlocked)
        ..sendEvent(CaptionBarEvent.stopTapped)
        ..sendEvent(CaptionBarEvent.captureEnded);
      await settle();
      expect(cubit.state.pause, isNull);
      expect(cubit.state.status, LiveCaptionsStatus.idle);
      await cubit.close();
    });

    test('unlocked while hot, the heat pause stays', () async {
      final cubit = await running();
      host.sendEvent(CaptionBarEvent.deviceLocked);
      await settle();
      when(() => conditions.latest).thenReturn(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.severe),
      );
      host.sendEvent(CaptionBarEvent.deviceUnlocked);
      await settle();
      expect(cubit.state.pause, LiveCaptionsPause.hot);
      await cubit.close();
    });
  });

  group('heat', () {
    test('a hot phone pauses transcription until it cools down', () async {
      final cubit = await running();
      heat.add(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
      await settle();
      expect(cubit.state.pause, LiveCaptionsPause.hot);
      expect(host.bar, const CaptionLine.notice('bar:hot'));
      host.sendAudio(block());
      await settle();
      expect(recognizer.recording.added, isEmpty);
      // Still hot: nothing new.
      heat.add(const DeviceConditionsSnapshot(thermal: ThermalStatus.critical));
      await settle();
      heat.add(const DeviceConditionsSnapshot(thermal: ThermalStatus.moderate));
      await settle();
      expect(cubit.state.pause, isNull);
      expect(host.bar, const CaptionLine.notice('bar:listening'));
      host.sendAudio(block());
      await settle();
      expect(recognizer.recording.added, hasLength(1));
      await cubit.close();
    });

    test('started hot, the captions wait', () async {
      when(() => conditions.latest).thenReturn(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.emergency),
      );
      final cubit = await running();
      expect(cubit.state.pause, LiveCaptionsPause.hot);
      expect(host.bar, const CaptionLine.notice('bar:hot'));
      await cubit.close();
    });

    test('heat while stopped changes nothing', () async {
      final cubit = await running();
      await cubit.stop();
      heat.add(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
      await settle();
      expect(cubit.state.pause, isNull);
      await cubit.close();
    });
  });

  group('transcript', () {
    test('is saved to History only when asked', () async {
      final cubit = await running(source: spanish);
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      verifyNever(() => history.add(any()));
      await cubit.saveToHistory();
      final saved =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(saved.text, 'Hola');
      expect(saved.translation, '[en] Hola');
      expect(saved.source, spanish);
      expect(saved.target, english);
      expect(saved.engineId, deepl.id);
      expect(saved.isFavorite, isFalse);
      expect(cubit.state.notice, LiveCaptionsNotice.saved);
      // Saving again updates the same entry.
      await cubit.saveToHistory();
      final again =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(again.id, saved.id);
      await cubit.close();
    });

    test('as a favourite while history is paused', () async {
      when(() => history.state).thenReturn(const HistoryState(incognito: true));
      final cubit = await running();
      recognizer.recording.phrase('Hello', language: 'en');
      await settle();
      await cubit.saveToHistory();
      final saved =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(saved.isFavorite, isTrue);
      expect(saved.detectedSource, 'en');
      expect(saved.engineName, 'Whisper');
      expect(cubit.state.notice, LiveCaptionsNotice.savedAsFavorite);
      await cubit.close();
    });

    test('a failed save says so', () async {
      when(() => history.add(any())).thenThrow(StateError('disk'));
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      await cubit.saveToHistory();
      expect(cubit.state.notice, LiveCaptionsNotice.saveFailed);
      await cubit.close();
    });

    test('nothing to save without words', () async {
      final cubit = await running();
      await cubit.saveToHistory();
      verifyNever(() => history.add(any()));
      expect(cubit.state.hasTranscript, isFalse);
      await cubit.close();
    });

    test('is cleared when stopped only', () async {
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      cubit.clear();
      expect(cubit.state.entries, hasLength(1));
      await cubit.stop();
      cubit.clear();
      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.detectedLanguage, isNull);
      await cubit.close();
    });
  });

  group('close', () {
    test('stops the capture and drops the recording', () async {
      final cubit = await running();
      final recording = recognizer.recording;
      await cubit.close();
      expect(host.stops, 1);
      expect(recording.cancelled, isTrue);
      // Late phrases change nothing.
      recording.phrase('Hola');
    });

    test('leaves a stopped capture alone', () async {
      final cubit = build();
      await cubit.load();
      await cubit.close();
      expect(host.stops, 0);
    });
  });

  test('the state compares by value', () {
    const state = LiveCaptionsState(source: Language.auto, target: english);
    expect(
      state,
      const LiveCaptionsState(source: Language.auto, target: english),
    );
    expect(state.copyWith(), state);
    expect(state.canStart, isFalse);
    expect(state.copyWith(status: LiveCaptionsStatus.idle).canStart, isTrue);
    expect(
      state.copyWith(status: LiveCaptionsStatus.starting).isActive,
      isTrue,
    );
    expect(const LiveCaptionsBehindException().toString(), contains('Behind'));
  });

  test('the default bar texts are English: hot and silence', () async {
    when(
      () => conditions.latest,
    ).thenReturn(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
    final cubit = LiveCaptionsCubit(
      host: host,
      repository: repository,
      engine: () => engine,
      source: Language.auto,
      target: english,
      recognizer: recognizer,
      conditions: conditions,
    );
    await cubit.load();
    await cubit.start();
    await settle();
    expect(host.bar, const CaptionLine.notice('Paused: the phone is hot'));
    heat.add(DeviceConditionsSnapshot.unknown);
    await settle();
    for (var i = 0; i < 200; i++) {
      host.sendAudio(block(0));
    }
    await settle();
    expect(host.bar.translation, startsWith('No sound'));
    await cubit.close();
  });

  test('a language the catalogue does not know is still the source', () async {
    final cubit = await running();
    recognizer.recording.phrase('Xyz', language: 'zz');
    await settle();
    expect(requests.single.source.code, 'zz');
    await cubit.close();
  });

  test('retrying leaves the translated phrases alone', () async {
    var fail = false;
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      if (fail) return Stream.error(StateError('offline'));
      return Stream.value(resultOf('ok ${request.text}'));
    });
    final cubit = await running();
    recognizer.recording.phrase('Uno', language: 'es');
    await settle();
    fail = true;
    recognizer.recording.phrase('Dos', language: 'es', index: 1);
    await settle();
    fail = false;
    cubit.retryTranslations();
    await settle();
    expect(cubit.state.entries.map((entry) => entry.translation), [
      'ok Uno',
      'ok Dos',
    ]);
    await cubit.close();
  });

  test('the default bar texts are English', () async {
    final cubit = LiveCaptionsCubit(
      host: host,
      repository: repository,
      engine: () => engine,
      source: Language.auto,
      target: english,
      recognizer: recognizer,
    );
    await cubit.load();
    await cubit.start();
    await settle();
    expect(host.bar, const CaptionLine.notice('Listening…'));
    await cubit.close();
  });
}
