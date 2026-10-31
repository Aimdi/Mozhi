import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

class _SilentOutput implements AudioOutput {
  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  Future<void> play(Uint8List bytes) async {}

  @override
  Future<void> setPlaybackRate(double rate) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// A device engine without voices, like Android with no TTS app (or one
/// without a voice for the language).
class _NoVoiceTts extends Fake implements DeviceTts {
  new({this.speakError});

  /// Thrown by [speak]; the language is then available.
  final Object? speakError;

  @override
  bool get isSupported => true;

  @override
  Future<bool> isLanguageAvailable(String languageTag) async =>
      speakError != null;

  @override
  DeviceVoice? get activeVoice => null;

  @override
  Future<void> setLanguage(String languageTag, {DeviceVoice? voice}) async {}

  @override
  Future<void> setSpeechRate({required bool slow, double rate = 1}) async {}

  @override
  Future<void> speak(String text) async {
    if (speakError case final Error error) throw error;
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

class _EnginesTts extends _NoVoiceTts implements DeviceTtsEngines {
  new(this.answer, {super.speakError});

  /// What [hasEngine] answers; an [Error] is thrown.
  final Object? answer;
  int asked = 0;

  @override
  Future<bool?> hasEngine() async {
    asked++;
    if (answer case final Error error) throw error;
    return answer as bool?;
  }
}

void main() {
  late _MockTranslationRepository repository;

  setUp(() {
    repository = _MockTranslationRepository();
    when(() => repository.instances).thenReturn(const []);
  });

  SpeechService service(DeviceTts device) => SpeechService(
    repository: repository,
    output: _SilentOutput(),
    deviceTts: device,
  );

  Future<SpeechUnavailableException> failure(SpeechService speech) async {
    try {
      await speech.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
    } on SpeechUnavailableException catch (error) {
      return error;
    }
    fail('Expected a SpeechUnavailableException');
  }

  group('SpeechService and a device without a speech engine', () {
    test('says that the device has no engine at all', () async {
      final device = _EnginesTts(false);
      final speech = service(device);

      final error = await failure(speech);

      expect(error.noDeviceEngine, isTrue);
      expect(error.cause, isNull);
      expect(device.asked, 1);
      expect(speech.current, isNull);
      expect(await speech.hasNoDeviceEngine(), isTrue);
    });

    test('not when it has one, or cannot tell', () async {
      for (final answer in [true, null, StateError('no engine list')]) {
        final device = _EnginesTts(answer);
        final speech = service(device);

        final error = await failure(speech);

        expect(error.noDeviceEngine, isFalse, reason: '$answer');
        expect(await speech.hasNoDeviceEngine(), isFalse, reason: '$answer');
      }
    });

    test('not when the engine cannot list engines', () async {
      final speech = service(_NoVoiceTts());

      expect((await failure(speech)).noDeviceEngine, isFalse);
      expect(await speech.hasNoDeviceEngine(), isFalse);
    });

    test('not when a device voice failed (it is there)', () async {
      final device = _EnginesTts(false, speakError: StateError('engine'));
      final speech = service(device);

      final error = await failure(speech);

      expect(error.noDeviceEngine, isFalse);
      expect(error.cause, isStateError);
      expect(device.asked, 0);
    });

    test('also when the Mozhi servers failed after it', () async {
      final allFailed = AllInstancesFailedException(
        'boom',
        engine: TranslationEngine.mozhi('google', 'Google'),
        instances: const [MozhiInstance(url: 'https://mozhi.example')],
        statusCode: 502,
      );
      when(() => repository.instances)
          .thenReturn(const [MozhiInstance(url: 'https://mozhi.example')]);
      when(
        () => repository.textToSpeech(
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      ).thenThrow(allFailed);
      final speech = service(_EnginesTts(false));

      final error = await failure(speech);

      expect(error.noDeviceEngine, isTrue);
      expect(error.cause, same(allFailed));
    });

    test('an engine is not looked for on unsupported platforms', () async {
      final speech = service(_UnsupportedTts(false));

      expect(await speech.hasNoDeviceEngine(), isFalse);
    });
  });

  group(SpeechUnavailableException, () {
    test('withoutCause keeps whether the device has an engine', () {
      final error = SpeechUnavailableException(
        'fr',
        cause: StateError('x'),
        noDeviceEngine: true,
      ).withoutCause();

      expect(error.languageCode, 'fr');
      expect(error.cause, isNull);
      expect(error.noDeviceEngine, isTrue);
      expect(
        const SpeechUnavailableException('fr').withoutCause().noDeviceEngine,
        isFalse,
      );
    });

    test('toString tells that the device has no engine', () {
      expect(
        const SpeechUnavailableException('fr', noDeviceEngine: true).toString(),
        'SpeechUnavailableException(fr, no device engine)',
      );
    });
  });
}

class _UnsupportedTts extends _EnginesTts {
  new(super.answer);

  @override
  bool get isSupported => false;
}
