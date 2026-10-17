import 'dart:typed_data';

import 'package:record/record.dart';

/// Records the microphone as 16 kHz mono little-endian 16-bit PCM (what
/// Whisper needs), so `WhisperSpeechRecognizerAdapter` can be tested
/// without a microphone.
abstract interface class PcmRecorder {
  /// Whether microphone access is granted; with [request] the system asks
  /// the user when it was never answered.
  Future<bool> hasPermission({bool request = true});

  /// Starts recording; the stream ends when [stop] is called.
  Future<Stream<Uint8List>> start();

  /// Stops recording.
  Future<void> stop();

  /// Releases the microphone for good.
  Future<void> dispose();
}

/// [PcmRecorder] over `record` (Android: `AudioRecord`, no Google code).
///
/// Records with Android's `VOICE_RECOGNITION` source (tuned for speech
/// recognition) and without Bluetooth SCO, like the system recogniser
/// (`SpeechToText.androidNoBluetooth`). The plugin is only touched on first
/// use.
// coverage:ignore-start
class RecordPcmRecorder implements PcmRecorder {
  new({AudioRecorder Function()? create})
    : _create = create ?? AudioRecorder.new;

  /// 16 kHz mono PCM16, the format Whisper reads.
  static const config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    androidConfig: AndroidRecordConfig(
      manageBluetooth: false,
      audioSource: AndroidAudioSource.voiceRecognition,
    ),
  );

  final AudioRecorder Function() _create;
  AudioRecorder? _recorder;

  AudioRecorder get _instance => _recorder ??= _create();

  @override
  Future<bool> hasPermission({bool request = true}) =>
      _instance.hasPermission(request: request);

  @override
  Future<Stream<Uint8List>> start() => _instance.startStream(config);

  @override
  Future<void> stop() async {
    await _recorder?.stop();
  }

  @override
  Future<void> dispose() async {
    final recorder = _recorder;
    _recorder = null;
    await recorder?.dispose();
  }
}

// coverage:ignore-end
