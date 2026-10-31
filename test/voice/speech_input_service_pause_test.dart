import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';

import 'helpers/fake_offline_recognizer.dart';
import 'helpers/fake_speech_recognizer.dart';

/// A timer that fires only when told to.
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

void main() {
  group('SpeechInputService.listen pause', () {
    late FakeSpeechRecognizer system;
    late FakeOfflineRecognizer whisper;
    late List<_FakeTimer> timers;
    late SpeechInputService service;

    setUp(() {
      system = FakeSpeechRecognizer();
      whisper = FakeOfflineRecognizer();
      timers = [];
      service = SpeechInputService(
        store: MemoryStore(),
        adapter: system,
        offlineAdapter: whisper,
        platformSupported: true,
        onDeviceSupported: true,
        timer: (duration, callback) {
          final timer = _FakeTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      );
    });

    tearDown(() => service.dispose());

    const pause = Duration(milliseconds: 800);
    const usual = SpeechListenRequest();

    List<_FakeTimer> active() => [
      for (final timer in timers)
        if (timer.isActive) timer,
    ];

    test('ends an offline session after that pause', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      expect(await service.listen('en', pause: pause), isTrue);
      expect(whisper.lastRequest.pauseFor, pause);
      // Whisper's voice activity detection measures it: no timer here.
      whisper.emitResult('Hello');
      expect(timers, isEmpty);
    });

    test('keeps the usual pause without one', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      expect(await service.listen('en'), isTrue);
      expect(whisper.lastRequest.pauseFor, usual.pauseFor);
    });

    test('the system recogniser keeps its own wait before any words', () async {
      expect(await service.listen('en', pause: pause), isTrue);
      expect(system.lastRequest.pauseFor, usual.pauseFor);
      expect(usual.pauseFor, const Duration(seconds: 3));
      system.emitResult(' ');
      expect(timers, isEmpty);
    });

    test(
      'stops the system recogniser that pause after the last words',
      () async {
        final results = <SpeechInputResult>[];
        final subscription = service.results.listen(results.add);
        expect(await service.listen('en', pause: pause), isTrue);
        system.emitResult('Good');
        expect(active().single.duration, pause);
        // Each new word starts the pause again; the same words don't.
        system.emitResult('Good morning');
        final second = active().single;
        expect(timers, hasLength(2));
        system.emitResult('Good morning');
        expect(timers, hasLength(2));
        second.fire();
        expect(system.stopCalls, 1);
        expect(service.state, const SpeechInputIdle());
        system.emitResult('Good morning', isFinal: true);
        await Future<void>.delayed(Duration.zero);
        expect(results.last.isFinal, isTrue);
        expect(results.last.text, 'Good morning');
        await subscription.cancel();
      },
    );

    test('a final result ends the pause', () async {
      expect(await service.listen('en', pause: pause), isTrue);
      system.emitResult('One');
      final first = timers.single;
      system.emitResult('One', isFinal: true);
      expect(first.isActive, isFalse);
      expect(await service.listen('en', pause: pause), isTrue);
      expect(system.stopCalls, 0);
      expect(service.state, isA<SpeechInputListening>());
    });

    test('stop, cancel and dispose end the pause', () async {
      expect(await service.listen('en', pause: pause), isTrue);
      system.emitResult('One');
      await service.stop();
      expect(active(), isEmpty);
      expect(await service.listen('en', pause: pause), isTrue);
      system.emitResult('Two');
      await service.cancel();
      expect(active(), isEmpty);
      expect(await service.listen('en', pause: pause), isTrue);
      system.emitResult('Three');
      await service.dispose();
      expect(active(), isEmpty);
    });

    test('dictation without a pause leaves the system recogniser', () async {
      expect(await service.listen('en'), isTrue);
      system.emitResult('Hello there');
      expect(timers, isEmpty);
      expect(system.lastRequest.pauseFor, usual.pauseFor);
    });
  });
}
