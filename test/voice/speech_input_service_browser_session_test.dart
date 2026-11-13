import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/transcribe/data/transcriber.dart';
import 'package:mozhi/voice/voice.dart';

import 'helpers/fake_speech_recognizer.dart';

class _FakeTimer implements Timer {
  new(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;
}

/// Sessions of the browser's recogniser, which marks no result final.
void main() {
  late FakeSpeechRecognizer recognizer;
  late List<SpeechInputState> states;
  late List<SpeechInputResult> results;
  late List<_FakeTimer> timers;

  SpeechInputService build({bool isWeb = true, String? deviceLocale}) {
    final service = SpeechInputService(
      store: MemoryStore(),
      adapter: recognizer,
      platformSupported: true,
      isWeb: isWeb,
      browserRecognizerAvailable: true,
      deviceLocale: () => deviceLocale,
      timer: (duration, callback) {
        final timer = _FakeTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(service.dispose);
    service.states.listen(states.add);
    service.results.listen(results.add);
    return service;
  }

  setUp(() {
    recognizer = FakeSpeechRecognizer()..localeList = const [];
    states = [];
    results = [];
    timers = [];
  });

  group('in the web app', () {
    test('the last words are the final result when the browser ends '
        'the session, before idle', () async {
      final service = build();
      await service.listen('en');
      recognizer
        ..emitResult('hello')
        ..emitResult('hello world')
        ..emitStatus(SpeechRecognizerStatus.notListening);
      await pumpEventQueue();

      expect(results.map((r) => (r.text, r.isFinal)), [
        ('hello', false),
        ('hello world', false),
        ('hello world', true),
      ]);
      expect(service.state, const SpeechInputIdle());
      // speech_to_text's late copy of the last words is dropped.
      recognizer.emitResult('hello world', isFinal: true);
      await pumpEventQueue();
      expect(results.where((r) => r.isFinal), hasLength(1));
    });

    test('a session without words ends without a final result', () async {
      final service = build();
      await service.listen('en');
      recognizer.emitStatus(SpeechRecognizerStatus.notListening);
      await pumpEventQueue();

      expect(results, isEmpty);
      expect(service.state, const SpeechInputIdle());
    });

    test('stop keeps listening for the last words until the browser ends '
        'the session', () async {
      final service = build();
      await service.listen('en');
      recognizer.emitResult('one');
      await service.stop();
      await service.stop();

      expect(service.state.isListening, isTrue);
      expect(recognizer.stopCalls, 1);
      recognizer
        ..emitResult('one two')
        ..emitStatus(SpeechRecognizerStatus.notListening);
      await pumpEventQueue();

      expect(results.last, const SpeechInputResult('one two', isFinal: true));
      expect(service.state, const SpeechInputIdle());
    });

    test('stop gives the browser a moment, then ends the session', () async {
      final service = build();
      await service.listen('en');
      recognizer.emitResult('late');
      await service.stop();
      final timer = timers.singleWhere(
        (t) => t.duration == SpeechInputService.browserStopTimeout,
      )..fire();
      await pumpEventQueue();

      expect(timer.isActive, isFalse);
      expect(results.last, const SpeechInputResult('late', isFinal: true));
      expect(service.state, const SpeechInputIdle());
    });

    test('a final result of the recogniser ends the stopped session', () async {
      final service = build();
      await service.listen('en');
      await service.stop();
      recognizer.emitResult('done', isFinal: true);
      await pumpEventQueue();

      expect(results.single, const SpeechInputResult('done', isFinal: true));
      expect(service.state, const SpeechInputIdle());
      expect(timers.where((t) => t.isActive), isEmpty);
    });

    test('cancel drops the last words', () async {
      final service = build();
      await service.listen('en');
      recognizer.emitResult('gone');
      await service.stop();
      await service.cancel();
      await pumpEventQueue();

      expect(results.where((r) => r.isFinal), isEmpty);
      expect(service.state, const SpeechInputIdle());
    });

    test(
      'Detect language listens in the device language and says so',
      () async {
        final service = build(deviceLocale: 'de-DE');
        await service.listen('auto');

        expect(recognizer.lastRequest.localeId, 'de-DE');
        expect(
          service.state,
          isA<SpeechInputListening>().having(
            (s) => s.assumedLocaleId,
            'assumedLocaleId',
            'de-DE',
          ),
        );
      },
    );

    test('a chosen language is not an assumed one', () async {
      final service = build(deviceLocale: 'de-DE');
      await service.listen('fr');

      expect(recognizer.lastRequest.localeId, 'fr-FR');
      expect((service.state as SpeechInputListening).assumedLocaleId, isNull);
    });

    test('without a device language the browser chooses', () async {
      final service = build();
      await service.listen(null);

      expect(recognizer.lastRequest.localeId, isNull);
      expect((service.state as SpeechInputListening).assumedLocaleId, isNull);
    });
  });

  group('in the Android app', () {
    test('stop is idle at once; the final result follows once', () async {
      final service = build(isWeb: false, deviceLocale: 'de-DE');
      await service.listen('auto');
      expect(recognizer.lastRequest.localeId, isNull);
      recognizer.emitResult('hi');
      await service.stop();
      expect(service.state, const SpeechInputIdle());

      recognizer
        ..emitStatus(SpeechRecognizerStatus.notListening)
        ..emitResult('hi there', isFinal: true)
        ..emitResult('hi there', isFinal: true);
      await pumpEventQueue();

      expect(results.where((r) => r.isFinal).map((r) => r.text), ['hi there']);
    });
  });

  group('Transcribe in the web app', () {
    test(
      'keeps each phrase the browser ends, and the last one on stop',
      () async {
        final service = build(deviceLocale: 'en-US');
        final transcriber = SystemTranscriber(
          service,
          restartDelay: Duration.zero,
        );
        final events = <TranscriberEvent>[];
        final done = Completer<void>();
        transcriber
            .listen(language: 'en')
            .listen(events.add, onDone: done.complete);
        await pumpEventQueue();

        recognizer
          ..emitResult('first phrase')
          ..emitStatus(SpeechRecognizerStatus.notListening);
        await pumpEventQueue();
        // It listens again for the next phrase.
        expect(recognizer.requests, hasLength(2));
        recognizer.emitResult('second');
        await pumpEventQueue();
        final stopping = transcriber.stop();
        recognizer.emitStatus(SpeechRecognizerStatus.notListening);
        await stopping;
        await done.future;

        final heard = [
          for (final event in events)
            if (event is TranscriberHeard) event.phrase.text,
        ];
        expect(heard, ['first phrase', 'second']);
      },
    );
  });
}
