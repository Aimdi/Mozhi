import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';

/// No offline speech recognition in a browser (see
/// `offline_speech_io.dart` for the app).
Future<OfflineSpeech?> createOfflineSpeech({
  required KeyValueStore store,
}) async => null;
