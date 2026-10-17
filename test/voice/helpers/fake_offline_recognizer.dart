import 'package:mozhi/voice/voice.dart';

import 'fake_speech_recognizer.dart';

/// Scriptable [OfflineSpeechRecognizerAdapter] for tests: a
/// [FakeSpeechRecognizer] whose [initialize] behaves like Whisper's (it
/// fails with [OfflineSpeechRecognizerAdapter.modelMissingCode] unless
/// [ready]).
class FakeOfflineRecognizer extends FakeSpeechRecognizer
    implements OfflineSpeechRecognizerAdapter {
  FakeOfflineRecognizer() {
    localeList = const [
      SpeechRecognizerLocale('en', 'English'),
      SpeechRecognizerLocale('de', 'German'),
      SpeechRecognizerLocale('jw', 'Javanese'),
    ];
    systemLocale = null;
  }

  /// Whether a model is installed.
  bool ready = true;
  Exception? readyError;
  int readyCalls = 0;

  @override
  Future<bool> isReady() async {
    readyCalls++;
    if (readyError case final error?) throw error;
    return ready;
  }

  @override
  Future<bool> initialize({
    required void Function(SpeechRecognizerError error) onError,
    required void Function(SpeechRecognizerStatus status) onStatus,
  }) async {
    if (!ready) {
      initErrors = const [
        SpeechRecognizerError(
          OfflineSpeechRecognizerAdapter.modelMissingCode,
          permanent: true,
        ),
      ];
      initResult = false;
    } else {
      initErrors = const [];
      initResult = initResultWhenReady;
    }
    return await super.initialize(onError: onError, onStatus: onStatus);
  }

  /// What [initialize] returns with a model (e.g. false for a denied
  /// microphone).
  bool initResultWhenReady = true;
}
