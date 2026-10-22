import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:whisper_speech/src/engine/ffi/bindings.dart';
import 'package:whisper_speech/src/engine/whisper_engine.dart';

/// Synchronous access to the native engine with one loaded Whisper model
/// and one loaded voice activity detector. Blocks the calling isolate: only
/// used inside the engine isolates (see `IsolateWhisperEngine` and
/// `IsolateWhisperVadEngine`).
final class NativeWhisperEngine {
  new(this._bindings);

  /// Opens the library ([WhisperBindings.open]) and checks its ABI.
  factory open({String? libraryPath}) {
    final WhisperBindings bindings;
    try {
      bindings = WhisperBindings(WhisperBindings.open(libraryPath));
    } on Object catch (error) {
      throw WhisperEngineException('Cannot load the native engine: $error');
    }
    final abi = bindings.abiVersion();
    if (abi != WhisperBindings.expectedAbiVersion) {
      throw WhisperEngineException(
        'Native engine ABI $abi, expected '
        '${WhisperBindings.expectedAbiVersion}',
      );
    }
    return NativeWhisperEngine(bindings);
  }

  final WhisperBindings _bindings;
  String? _loadedPath;
  Pointer<NativeWhisperModel> _model = nullptr;
  String? _vadPath;
  Pointer<NativeWhisperVad> _vad = nullptr;

  /// Engine version, e.g. `whisper.cpp 1.9.5 (ggml 0.26.0, CPU)`.
  String get version => _bindings.version().toDartString();

  /// Path of the loaded model, if any.
  String? get loadedModel => _loadedPath;

  WhisperTranscription transcribe(
    String modelPath,
    Float32List samples, {
    String? language,
    int threads = 0,
  }) {
    final model = _load(modelPath);
    return using((arena) {
      final input = arena<Float>(samples.isEmpty ? 1 : samples.length);
      input.asTypedList(samples.length).setAll(0, samples);
      final detected = arena<Uint8>(WhisperBindings.languageSize);
      final code = (language == null || language.isEmpty) ? 'auto' : language;
      final output = _bindings.transcribe(
        model,
        input,
        samples.length,
        code.toNativeUtf8(allocator: arena),
        threads,
        detected,
        WhisperBindings.languageSize,
      );
      if (output == nullptr) _fail('transcribe');
      final String text;
      try {
        text = output.toDartString();
      } finally {
        _bindings.freeString(output);
      }
      final found = detected.cast<Utf8>().toDartString();
      return WhisperTranscription(text, language: found.isEmpty ? null : found);
    });
  }

  /// Speech probabilities of the windows [samples] complete in the stream
  /// fed to the detector with the VAD model at [modelPath] (see
  /// `WhisperVadEngine.detect`). Another model starts a new stream.
  WhisperVadFrames detectSpeech(String modelPath, Float32List samples) {
    final vad = _loadVad(modelPath);
    final frameSize = _bindings.vadFrameSize(vad);
    // Fewer than one window may be kept from earlier calls.
    final capacity = samples.length ~/ frameSize + 1;
    return using((arena) {
      final input = arena<Float>(samples.isEmpty ? 1 : samples.length);
      input.asTypedList(samples.length).setAll(0, samples);
      final output = arena<Float>(capacity);
      final count = _bindings.vadProcess(
        vad,
        input,
        samples.length,
        output,
        capacity,
      );
      if (count < 0) _fail('detect speech');
      return WhisperVadFrames(
        Float32List.fromList(output.asTypedList(count)),
        frameSize: frameSize,
      );
    });
  }

  /// Starts a new stream for [detectSpeech].
  void resetSpeech() {
    if (_vad != nullptr) _bindings.vadReset(_vad);
  }

  /// Unloads the model or detector at [modelPath], if loaded.
  void release(String modelPath) {
    if (_loadedPath == modelPath) _freeModel();
    if (_vadPath == modelPath) _freeVad();
  }

  void dispose() {
    _freeModel();
    _freeVad();
  }

  void _freeModel() {
    if (_model != nullptr) _bindings.modelFree(_model);
    _model = nullptr;
    _loadedPath = null;
  }

  void _freeVad() {
    if (_vad != nullptr) _bindings.vadFree(_vad);
    _vad = nullptr;
    _vadPath = null;
  }

  Pointer<NativeWhisperVad> _loadVad(String path) {
    if (_vadPath == path && _vad != nullptr) return _vad;
    _freeVad();
    final vad = using(
      (arena) => _bindings.vadLoad(path.toNativeUtf8(allocator: arena), 1),
    );
    if (vad == nullptr) _fail('load');
    _vad = vad;
    _vadPath = path;
    return vad;
  }

  Pointer<NativeWhisperModel> _load(String path) {
    if (_loadedPath == path && _model != nullptr) return _model;
    _freeModel();
    final model = using(
      (arena) => _bindings.modelLoad(path.toNativeUtf8(allocator: arena), 0),
    );
    if (model == nullptr) _fail('load');
    _model = model;
    _loadedPath = path;
    return model;
  }

  Never _fail(String operation) {
    final error = _bindings.lastError();
    final message = error == nullptr ? 'unknown error' : error.toDartString();
    if (message == 'cancelled') throw const WhisperCancelledException();
    throw WhisperEngineException('$operation: $message');
  }
}
