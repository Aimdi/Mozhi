import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class _MockSpeechToText extends Mock implements SpeechToText;

void main() {
  late _MockSpeechToText speech;
  late SpeechToTextAdapter adapter;
  late int created;

  setUpAll(() {
    registerFallbackValue(SpeechListenOptions());
  });

  setUp(() {
    speech = _MockSpeechToText();
    created = 0;
    adapter = SpeechToTextAdapter(
      create: () {
        created++;
        return speech;
      },
    );
  });

  group(SpeechToTextAdapter, () {
    test('creates the plugin lazily, once', () async {
      expect(SpeechToTextAdapter(), isA<SpeechRecognizerAdapter>());
      expect(created, 0);
      when(() => speech.hasPermission).thenAnswer((_) async => true);
      expect(await adapter.hasPermission(), isTrue);
      expect(await adapter.hasPermission(), isTrue);
      expect(created, 1);
    });

    test('initialize disables Bluetooth and maps callbacks', () async {
      when(
        () => speech.initialize(
          onError: any(named: 'onError'),
          onStatus: any(named: 'onStatus'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => true);
      final errors = <SpeechRecognizerError>[];
      final statuses = <SpeechRecognizerStatus>[];

      expect(
        await adapter.initialize(onError: errors.add, onStatus: statuses.add),
        isTrue,
      );

      final captured = verify(
        () => speech.initialize(
          onError: captureAny(named: 'onError'),
          onStatus: captureAny(named: 'onStatus'),
          options: captureAny(named: 'options'),
        ),
      ).captured;
      final onError = captured[0] as SpeechErrorListener;
      final onStatus = captured[1] as SpeechStatusListener;
      expect(captured[2], [SpeechToText.androidNoBluetooth]);

      onError(SpeechRecognitionError('error_no_match', true));
      expect(errors, [
        const SpeechRecognizerError('error_no_match', permanent: true),
      ]);

      onStatus('listening');
      onStatus('notListening');
      onStatus('done');
      onStatus('something else');
      expect(statuses, [
        SpeechRecognizerStatus.listening,
        SpeechRecognizerStatus.notListening,
        SpeechRecognizerStatus.done,
      ]);
    });

    test('maps locales and the system locale', () async {
      when(() => speech.locales()).thenAnswer(
        (_) async => [
          LocaleName('en_US', 'English'),
          LocaleName('fr_FR', 'French'),
        ],
      );
      when(() => speech.systemLocale())
          .thenAnswer((_) async => LocaleName('en_US', 'English'));
      expect(await adapter.locales(), const [
        SpeechRecognizerLocale('en_US', 'English'),
        SpeechRecognizerLocale('fr_FR', 'French'),
      ]);
      expect(await adapter.systemLocaleId(), 'en_US');

      when(() => speech.systemLocale()).thenAnswer((_) async => null);
      expect(await adapter.systemLocaleId(), isNull);
    });

    test('listen forwards the request and maps results', () async {
      when(
        () => speech.listen(
          onResult: any(named: 'onResult'),
          onSoundLevelChange: any(named: 'onSoundLevelChange'),
          listenOptions: any(named: 'listenOptions'),
        ),
      ).thenAnswer((_) async {});
      final results = <(String, bool)>[];
      final levels = <double>[];

      await adapter.listen(
        request: const SpeechListenRequest(localeId: 'fr_FR', onDevice: true),
        onResult: (text, {required isFinal}) => results.add((text, isFinal)),
        onSoundLevel: levels.add,
      );

      final captured = verify(
        () => speech.listen(
          onResult: captureAny(named: 'onResult'),
          onSoundLevelChange: captureAny(named: 'onSoundLevelChange'),
          listenOptions: captureAny(named: 'listenOptions'),
        ),
      ).captured;
      final onResult = captured[0] as SpeechResultListener;
      final onLevel = captured[1] as SpeechSoundLevelChange;
      final options = captured[2] as SpeechListenOptions;

      expect(options.localeId, 'fr_FR');
      expect(options.onDevice, isTrue);
      expect(options.partialResults, isTrue);
      expect(options.listenMode, ListenMode.dictation);
      expect(options.pauseFor, const Duration(seconds: 3));
      expect(options.listenFor, const Duration(seconds: 60));
      expect(options.autoPunctuation, isTrue);
      expect(options.cancelOnError, isTrue);

      onResult(
        SpeechRecognitionResult(const [
          SpeechRecognitionWords('bonjour', null, 0.9),
        ], ResultType.partial.value),
      );
      onResult(
        SpeechRecognitionResult(const [
          SpeechRecognitionWords('Bonjour.', null, 0.9),
        ], ResultType.finalResult.value),
      );
      onLevel(4.5);
      expect(results, [('bonjour', false), ('Bonjour.', true)]);
      expect(levels, [4.5]);
    });

    test('stop and cancel delegate to the plugin', () async {
      when(() => speech.stop()).thenAnswer((_) async {});
      when(() => speech.cancel()).thenAnswer((_) async {});
      await adapter.stop();
      await adapter.cancel();
      verify(() => speech.stop()).called(1);
      verify(() => speech.cancel()).called(1);
    });
  });

  group('unanswered locale queries', () {
    const timeout = Duration(milliseconds: 20);

    /// What `speech_to_text` 7.5 does on Android 13+ without an on-device
    /// recogniser: the locale query is never answered.
    void neverAnswerLocales() {
      when(() => speech.locales())
          .thenAnswer((_) => Completer<List<LocaleName>>().future);
      when(() => speech.systemLocale())
          .thenAnswer((_) => Completer<LocaleName?>().future);
    }

    setUp(() {
      adapter = SpeechToTextAdapter(
        create: () => speech,
        localeQueryTimeout: timeout,
      );
    });

    test('wait two seconds by default', () {
      expect(
        SpeechToTextAdapter.defaultLocaleQueryTimeout,
        const Duration(seconds: 2),
      );
      expect(
        SpeechToTextAdapter().localeQueryTimeout,
        SpeechToTextAdapter.defaultLocaleQueryTimeout,
      );
    });

    test('give no locales and no system locale, and are not '
        'repeated', () async {
      neverAnswerLocales();
      expect(await adapter.locales(), isEmpty);
      expect(await adapter.systemLocaleId(), isNull);
      expect(await adapter.locales(), isEmpty);
      verify(() => speech.locales()).called(1);
      verifyNever(() => speech.systemLocale());
    });

    test('an unanswered system locale stops locale queries too', () async {
      neverAnswerLocales();
      expect(await adapter.systemLocaleId(), isNull);
      expect(await adapter.locales(), isEmpty);
      verifyNever(() => speech.locales());
    });

    test('errors still reach the caller, and later queries are '
        'tried', () async {
      when(() => speech.locales())
          .thenAnswer((_) async => throw PlatformException(code: 'failed'));
      await expectLater(adapter.locales(), throwsA(isA<PlatformException>()));

      when(() => speech.locales())
          .thenAnswer((_) async => [LocaleName('fr_FR', 'French')]);
      expect(await adapter.locales(), const [
        SpeechRecognizerLocale('fr_FR', 'French'),
      ]);
    });

    test('a session still starts, in the chosen language, without '
        'waiting again', () async {
      neverAnswerLocales();
      when(
        () => speech.initialize(
          onError: any(named: 'onError'),
          onStatus: any(named: 'onStatus'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => true);
      when(
        () => speech.listen(
          onResult: any(named: 'onResult'),
          onSoundLevelChange: any(named: 'onSoundLevelChange'),
          listenOptions: any(named: 'listenOptions'),
        ),
      ).thenAnswer((_) async {});
      when(() => speech.cancel()).thenAnswer((_) async {});
      final service = SpeechInputService(
        store: MemoryStore(),
        adapter: adapter,
        platformSupported: true,
        onDeviceSupported: true,
      );
      addTearDown(service.dispose);
      final owner = Object();

      final elapsed = Stopwatch()..start();
      expect(await service.listen('fr', owner: owner), isTrue);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(service.state, SpeechInputListening(owner: owner));
      await service.cancel();
      expect(await service.listen('de'), isTrue);

      final requests = verify(
        () => speech.listen(
          onResult: any(named: 'onResult'),
          onSoundLevelChange: any(named: 'onSoundLevelChange'),
          listenOptions: captureAny(named: 'listenOptions'),
        ),
      ).captured.cast<SpeechListenOptions>();
      expect(requests.map((options) => options.localeId), ['fr-FR', 'de-DE']);
      verify(() => speech.locales()).called(1);
    });
  });
}
