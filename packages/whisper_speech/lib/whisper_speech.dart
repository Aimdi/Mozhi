/// Offline speech recognition for Mozhi with OpenAI's Whisper models on
/// whisper.cpp (no Google services): model catalog, verified downloads and
/// imports, PCM helpers and a [WhisperSpeech] engine running in a
/// background isolate. Safe to import on every platform (the native code
/// is only used where `dart:ffi` exists).
library;

import 'package:whisper_speech/src/whisper_speech.dart' show WhisperSpeech;

export 'src/catalog.dart';
export 'src/catalog_asset.dart';
export 'src/engine/engine_factory.dart';
export 'src/engine/whisper_engine.dart';
export 'src/languages.dart';
export 'src/model_manager.dart';
export 'src/pcm.dart';
export 'src/whisper_speech.dart';
