import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/engine/ffi/native_engine.dart';
import 'package:meta/meta.dart';

/// What [FakeLlamaNative] does (it runs in the engine isolate: everything
/// here must be sendable).
@immutable
final class FakeScript {
  const new({
    this.pieces = const ['Hel', 'lo'],
    this.endless = false,
    this.pieceDelay = Duration.zero,
    this.echoRequest = false,
    this.loadError,
    this.beginError,
    this.nextError,
    this.crashOnNext = false,
    this.dieOnNext = false,
    this.finishReason = LlamaFinishReason.stop,
  });

  /// Returned one by one by `next()`.
  final List<String> pieces;

  /// Repeats [pieces] until cancelled.
  final bool endless;

  /// Blocks `next()` this long (like the native decode).
  final Duration pieceDelay;

  /// The first piece describes the request (to check what reached the
  /// isolate).
  final bool echoRequest;

  final LlamaEngineException? loadError;
  final LlamaEngineException? beginError;
  final LlamaEngineException? nextError;

  /// `next()` throws a [StateError] (not an engine exception).
  final bool crashOnNext;

  /// `next()` ends the engine isolate.
  final bool dieOnNext;

  final LlamaFinishReason finishReason;
}

/// A [LlamaNative] without the library, for the isolate protocol tests.
final class FakeLlamaNative implements LlamaNative {
  new(this.script);

  final FakeScript script;
  String? _loaded;
  LlamaGenerateRequest? _request;
  int _cancelFlag = 0;
  int _next = 0;

  @override
  String get library => 'fake-library';

  @override
  String get engine => 'fake engine';

  @override
  String? get loadedModelPath => _loaded;

  @override
  LlamaModelInfo load(
    String path, {
    required int contextSize,
    required int threads,
  }) {
    if (script.loadError case final error?) throw error;
    if (path == 'crash') throw ArgumentError('bad path');
    if (path == 'die') Isolate.exit();
    _loaded = path;
    return LlamaModelInfo(
      architecture: 'fake',
      name: path,
      contextLength: 8192,
      parameters: threads,
      sizeBytes: 1,
      chatTemplate: true,
      contextSize: contextSize,
      engine: engine,
    );
  }

  @override
  void unload() => _loaded = null;

  @override
  int countTokens(List<LlamaChatMessage> messages) {
    if (_loaded == null) throw const LlamaNotLoadedException();
    return messages.fold(0, (sum, message) => sum + message.content.length);
  }

  @override
  void begin(LlamaGenerateRequest request, {int cancelFlag = 0}) {
    if (_loaded == null) throw const LlamaNotLoadedException();
    if (script.beginError case final error?) throw error;
    _request = request;
    _cancelFlag = cancelFlag;
    _next = 0;
  }

  @override
  String? next() {
    final request = _request;
    if (request == null) throw StateError('not generating');
    if (script.dieOnNext) Isolate.exit();
    if (script.crashOnNext) throw StateError('boom');
    if (script.nextError case final error?) throw error;
    if (script.pieceDelay > Duration.zero) sleep(script.pieceDelay);
    if (_cancelFlag != 0 &&
        Pointer<Int32>.fromAddress(_cancelFlag).value != 0) {
      throw const LlamaCancelledException();
    }
    final index = _next++;
    if (script.echoRequest && index == 0) {
      final sampling = request.sampling;
      return 'messages=${request.messages.map((m) => m.role.name).join(',')} '
          'max=${request.maxTokens} json=${request.jsonOutput} '
          'stop=${request.stop.join('|')} temperature=${sampling.temperature} '
          'seed=${sampling.seed} flag=${_cancelFlag != 0}';
    }
    final at = script.echoRequest ? index - 1 : index;
    if (!script.endless && at >= script.pieces.length) return null;
    return script.pieces[at % script.pieces.length];
  }

  @override
  LlamaGenerateStats stats() => LlamaGenerateStats(
    promptTokens: _request?.messages.length ?? 0,
    generatedTokens: _next,
    finishReason: script.finishReason,
  );

  @override
  void end() => _request = null;

  @override
  void dispose() => _loaded = null;
}
