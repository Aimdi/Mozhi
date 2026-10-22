import 'dart:async';
import 'dart:collection';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/translation_json.dart';
import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/model_manager.dart';
import 'package:translation_repository/translation_repository.dart';

/// [BergamotBatchEngine] of the web app: the WebAssembly engine in the
/// worker behind [channel] (`web/bergamot/worker.js`), which reads the
/// models from the browser's storage (the paths of [ModelPaths] are
/// relative to it, see `OpfsModelManager`).
///
/// Works like the isolate engine of the Android app: the worker keeps up to
/// [maxLoadedModels] models loaded (least recently used are unloaded first;
/// a pivot needs two) and translates one request at a time. Requests wait
/// on this side and are sent one by one, so a request whose `abort`
/// completes while it waits is dropped without reaching the worker; one
/// already running finishes there (WebAssembly cannot be interrupted), but
/// its caller gets [OfflineTranslationCancelledException] at once.
///
/// Marian's workspace is [workspaceMb] (Firefox uses 128 MB; a browser
/// tab, especially on a phone, has less memory to spare).
final class WorkerBergamotEngine implements BergamotBatchEngine {
  new(this.channel, {this.maxLoadedModels = 2, this.workspaceMb = 32})
    : assert(maxLoadedModels >= 2, 'A pivot needs two loaded models'),
      assert(workspaceMb >= 8, 'Marian needs a workspace');

  final BergamotWorkerChannel channel;
  final int maxLoadedModels;
  final int workspaceMb;

  final Queue<_Job> _waiting = Queue();
  _Job? _running;
  Future<void>? _configured;

  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) async {
    final results = await translateBatch(chain, [text], html: html);
    return results.single.text;
  }

  @override
  Future<List<OfflineTranslation>> translateBatch(
    List<ModelPaths> chain,
    List<String> texts, {
    bool html = false,
    bool details = false,
    Future<void>? abort,
  }) async {
    if (texts.isEmpty) return const [];
    final json = await _enqueue(
      () => channel.request('translate', {
        'chain': [for (final model in chain) modelSpec(model)],
        'texts': texts,
        'html': html,
        'details': details,
      }),
      abort: abort,
    );
    if (json is! String) {
      throw const BergamotEngineException('Invalid engine output: no JSON');
    }
    return parseBergamotTranslations(json, count: texts.length);
  }

  @override
  Future<void> preload(List<ModelPaths> chain) async {
    await _enqueue(
      () => channel.request('preload', {
        'chain': [for (final model in chain) modelSpec(model)],
      }),
    );
  }

  @override
  Future<void> trim() async {
    await _enqueue(() => channel.request('trim'));
  }

  @override
  Future<void> release(String key) async {
    await _enqueue(() => channel.request('release', {'key': key}));
  }

  /// Unloads every model and drops the WebAssembly instance (its memory
  /// goes back to the browser); the next request starts a new one.
  @override
  Future<void> dispose() async {
    await _enqueue(() => channel.request('dispose'));
  }

  /// What the worker needs to load [model]: its files and its languages
  /// (the engine splits sentences with the browser's `Intl.Segmenter` for
  /// the source language), read from [ModelPaths.key] (`<pair>/<version>`,
  /// e.g. `en-de/run1`).
  static Map<String, Object?> modelSpec(ModelPaths model) {
    final pair = model.key.split('/').first;
    final dash = pair.indexOf('-');
    return {
      'key': model.key,
      'source': dash > 0 ? pair.substring(0, dash) : 'und',
      'target': dash > 0 ? pair.substring(dash + 1) : 'und',
      'model': model.model,
      'shortlist': model.shortlist,
      'sourceVocab': model.sourceVocab,
      'targetVocab': ?model.targetVocab,
    };
  }

  /// Runs [send] after the requests before it; with [abort], drops it
  /// while it waits, or releases its caller while it runs.
  Future<Object?> _enqueue(
    Future<Object?> Function() send, {
    Future<void>? abort,
  }) {
    final job = _Job(send);
    _waiting.add(job);
    if (abort != null) {
      void cancel() {
        if (job.completer.isCompleted) return;
        _waiting.remove(job);
        job.completer.completeError(
          const OfflineTranslationCancelledException(),
        );
      }

      unawaited(abort.then((_) => cancel(), onError: (Object _) => cancel()));
    }
    _next();
    return job.completer.future;
  }

  void _next() {
    if (_running != null || _waiting.isEmpty) return;
    final job = _running = _waiting.removeFirst();
    unawaited(_run(job));
  }

  Future<void> _run(_Job job) async {
    try {
      await (_configured ??= _configure());
      final result = await job.send();
      if (!job.completer.isCompleted) job.completer.complete(result);
    } on BergamotWorkerException catch (error) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(error.toEngineException());
      }
    } on Object catch (error, stackTrace) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(error, stackTrace);
      }
    } finally {
      _running = null;
      _next();
    }
  }

  Future<void> _configure() async {
    try {
      await channel.request('configure', {
        'maxModels': maxLoadedModels,
        'workspace': workspaceMb,
      });
    } on Object {
      // Tried again before the next request.
      _configured = null;
      rethrow;
    }
  }
}

final class _Job {
  new(this.send);

  final Future<Object?> Function() send;
  final completer = Completer<Object?>();
}
