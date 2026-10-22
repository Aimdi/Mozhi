import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/practice/data/practice_speech.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/pcm_recorder.dart';
import 'package:mozhi/voice/speech_recognizer_adapter.dart';

class _MockSpeech extends Mock implements OfflineSpeech;

class _MockRecorder extends Mock implements PcmRecorder;

/// An offline recogniser the test drives.
class _FakeAdapter implements OfflineSpeechRecognizerAdapter {
  bool ready = true;
  bool initializes = true;
  String? initError;
  Error? listenError;
  SpeechListenRequest? request;
  void Function(SpeechRecognizerError error)? onError;
  void Function(SpeechRecognizerStatus status)? onStatus;
  SpeechRecognizerResultListener? onResult;
  void Function(double level)? onSoundLevel;
  int stops = 0;
  int cancels = 0;
  Error? stopError;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<bool> initialize({
    required void Function(SpeechRecognizerError error) onError,
    required void Function(SpeechRecognizerStatus status) onStatus,
  }) async {
    this.onError = onError;
    this.onStatus = onStatus;
    if (initError case final code?) {
      onError(SpeechRecognizerError(code, permanent: true));
    }
    return initializes;
  }

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<List<SpeechRecognizerLocale>> locales() async => const [];

  @override
  Future<String?> systemLocaleId() async => null;

  @override
  Future<void> listen({
    required SpeechListenRequest request,
    required SpeechRecognizerResultListener onResult,
    required void Function(double level) onSoundLevel,
  }) async {
    if (listenError case final error?) throw error;
    this.request = request;
    this.onResult = onResult;
    this.onSoundLevel = onSoundLevel;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (stopError case final error?) throw error;
  }

  @override
  Future<void> cancel() async => cancels++;
}

void main() {
  group(WhisperPracticeRecognizer, () {
    late _FakeAdapter adapter;
    late WhisperPracticeRecognizer recognizer;

    setUp(() {
      adapter = _FakeAdapter();
      recognizer = WhisperPracticeRecognizer(adapter: adapter);
    });

    test('is unsupported without Whisper', () async {
      expect(
        await WhisperPracticeRecognizer().availability(),
        PracticeSpeechAvailability.unsupported,
      );
      final speech = _MockSpeech();
      when(() => speech.isAvailable).thenReturn(false);
      expect(
        await WhisperPracticeRecognizer(
          speech: speech,
          adapter: adapter,
        ).availability(),
        PracticeSpeechAvailability.unsupported,
      );
      await expectLater(
        WhisperPracticeRecognizer().listen('pt'),
        throwsA(
          isA<PracticeSpeechException>().having(
            (e) => e.failure,
            'failure',
            PracticeSpeechFailure.engine,
          ),
        ),
      );
      await WhisperPracticeRecognizer().stop();
      await WhisperPracticeRecognizer().dispose();
    });

    test('runs Whisper of the offline speech by default', () async {
      final speech = _MockSpeech();
      final recorder = _MockRecorder();
      when(() => speech.isAvailable).thenReturn(true);
      when(speech.isReady).thenAnswer((_) async => true);
      when<Future<void>>(recorder.dispose).thenAnswer((_) async {});
      final whisper = WhisperPracticeRecognizer(
        speech: speech,
        recorder: recorder,
      );
      expect(await whisper.availability(), PracticeSpeechAvailability.ready);
      when(speech.isReady).thenThrow(StateError('broken'));
      expect(
        await whisper.availability(),
        PracticeSpeechAvailability.modelMissing,
      );
      await whisper.dispose();
      verify<Future<void>>(recorder.dispose).called(1);
    });

    test('says whether a model is installed', () async {
      expect(await recognizer.availability(), PracticeSpeechAvailability.ready);
      adapter.ready = false;
      expect(
        await recognizer.availability(),
        PracticeSpeechAvailability.modelMissing,
      );
    });

    test('knows the languages Whisper knows', () {
      expect(recognizer.supportsLanguage('pt-BR'), isTrue);
      expect(recognizer.supportsLanguage('fil'), isTrue);
      expect(recognizer.supportsLanguage('yue'), isFalse);
      expect(recognizer.supportsLanguage('auto'), isFalse);
    });

    test(
      'listens in the language on the device and returns the text',
      () async {
        final levels = <double>[];
        var transcribing = false;
        final heard = recognizer.listen(
          'pt',
          onLevel: levels.add,
          onTranscribing: () => transcribing = true,
        );
        await pumpEventQueue();
        expect(adapter.request!.localeId, 'pt');
        expect(adapter.request!.onDevice, isTrue);
        expect(adapter.request!.listenFor, maxPracticeRecording);
        expect(adapter.request!.pauseFor, WhisperPracticeRecognizer.pause);
        adapter.onSoundLevel!(-35);
        adapter.onSoundLevel!(0);
        expect(levels, [0.5, 1]);
        await recognizer.stop();
        expect(adapter.stops, 1);
        adapter.onStatus!(SpeechRecognizerStatus.transcribing);
        expect(transcribing, isTrue);
        adapter.onResult!('partial', isFinal: false);
        adapter.onResult!('  bom dia ', isFinal: true);
        expect(await heard, 'bom dia');
        // Nothing to stop any more.
        await recognizer.stop();
        expect(adapter.stops, 1);
      },
    );

    test('maps the recogniser errors', () async {
      final expected = {
        'error_permission': PracticeSpeechFailure.permissionDenied,
        OfflineSpeechRecognizerAdapter.modelMissingCode:
            PracticeSpeechFailure.modelMissing,
        'error_no_match': PracticeSpeechFailure.noSpeech,
        'error_audio_error': PracticeSpeechFailure.audio,
        OfflineSpeechRecognizerAdapter.engineErrorCode:
            PracticeSpeechFailure.engine,
      };
      for (final MapEntry(key: code, value: failure) in expected.entries) {
        final heard = recognizer.listen('pt');
        await pumpEventQueue();
        adapter.onError!(SpeechRecognizerError(code, permanent: false));
        await expectLater(
          heard,
          throwsA(
            isA<PracticeSpeechException>().having(
              (e) => e.failure,
              'failure',
              failure,
            ),
          ),
        );
      }
      expect(
        const PracticeSpeechException(PracticeSpeechFailure.audio).toString(),
        'PracticeSpeechException(audio)',
      );
    });

    test('fails when the recogniser cannot start', () async {
      adapter
        ..initializes = false
        ..initError = 'error_permission';
      await expectLater(
        recognizer.listen('pt'),
        throwsA(
          isA<PracticeSpeechException>().having(
            (e) => e.failure,
            'failure',
            PracticeSpeechFailure.permissionDenied,
          ),
        ),
      );
      adapter.initError = null;
      await expectLater(
        recognizer.listen('pt'),
        throwsA(isA<PracticeSpeechException>()),
      );
      adapter
        ..initializes = true
        ..listenError = StateError('mic');
      await expectLater(
        recognizer.listen('pt'),
        throwsA(
          isA<PracticeSpeechException>().having(
            (e) => e.failure,
            'failure',
            PracticeSpeechFailure.audio,
          ),
        ),
      );
    });

    test('cancel drops the recording', () async {
      final heard = recognizer.listen('pt');
      await pumpEventQueue();
      final failed = expectLater(
        heard,
        throwsA(
          isA<PracticeSpeechException>().having(
            (e) => e.failure,
            'failure',
            PracticeSpeechFailure.cancelled,
          ),
        ),
      );
      await recognizer.cancel();
      await failed;
      expect(adapter.cancels, 1);
      // A late result is ignored.
      adapter.onResult!('late', isFinal: true);
      await recognizer.cancel();
      expect(adapter.cancels, 1);
    });

    test('a failing stop still waits for the result', () async {
      adapter.stopError = StateError('stop');
      final heard = recognizer.listen('pt');
      await pumpEventQueue();
      await recognizer.stop();
      adapter.onResult!('olá', isFinal: true);
      expect(await heard, 'olá');
    });

    test('listening again cancels the previous recording', () async {
      final first = recognizer.listen('pt');
      await pumpEventQueue();
      final failed = expectLater(
        first,
        throwsA(isA<PracticeSpeechException>()),
      );
      final second = recognizer.listen('es');
      await failed;
      await pumpEventQueue();
      adapter.onResult!('hola', isFinal: true);
      expect(await second, 'hola');
      await recognizer.dispose();
    });
  });
}
