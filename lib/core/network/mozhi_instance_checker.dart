import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi_api/mozhi_api.dart';

/// The Mozhi engine of the app's engine id [engineId] (`mozhi:deepl` ->
/// `deepl`), or null when it is not a Mozhi engine (or none is chosen).
String? mozhiEngineOf(String? engineId) {
  const prefix = 'mozhi:';
  if (engineId == null || !engineId.startsWith(prefix)) return null;
  final engine = engineId.substring(prefix.length);
  return engine.isEmpty ? null : engine;
}

/// Creates a client for the Mozhi instance at [baseUrl] whose requests
/// give up after [timeout].
typedef MozhiCheckClientFactory = MozhiApiClient Function(
  Uri baseUrl,
  Duration timeout,
);

/// What is known about an instance's health this session.
sealed class InstanceHealth extends Equatable {
  const new();
}

/// A check is running.
final class InstanceChecking extends InstanceHealth {
  const new();

  @override
  List<Object?> get props => const [];
}

/// `GET /api/engines` answered within [latency] with [engines] (id ->
/// display name, see `MozhiApiClient.getEngines`).
final class InstanceOnline extends InstanceHealth {
  const new({required this.latency, required this.engines});

  final Duration latency;
  final Map<String, String> engines;

  @override
  List<Object?> get props => [latency, engines];
}

/// The check failed with [error] (a `MozhiApiException`, possibly one the
/// network policy refused, see `NetworkPolicyError.of`).
final class InstanceOffline extends InstanceHealth {
  const new(this.error);

  final Object error;

  @override
  List<Object?> get props => [error];
}

/// A test translation that worked: [text] is `hello` translated to German
/// by [engineName] ([engineId]) in [latency].
final class InstanceTestResult extends Equatable {
  const new({
    required this.engineId,
    required this.engineName,
    required this.text,
    required this.latency,
  });

  final String engineId;
  final String engineName;
  final String text;
  final Duration latency;

  @override
  List<Object?> get props => [engineId, engineName, text, latency];
}

/// The instance answered but has no engine enabled.
class InstanceHasNoEnginesException implements Exception {
  const new();

  @override
  String toString() => 'InstanceHasNoEnginesException';
}

/// Checks Mozhi instances on request — never by itself, never at startup —
/// and remembers the results in memory for the session (they are gone when
/// the app restarts).
///
/// * [check]: `GET /api/engines` with the short [checkTimeout]; stores the
///   latency and the engine list ([InstanceOnline]) or the error
///   ([InstanceOffline]).
/// * [test]: translates `hello` from English to German with the engine
///   the app uses when the instance offers it, else the first available
///   one ([testEngineOrder]), and reports the result and its latency, so
///   a server whose engine fails (an HTTP 500) fails the test.
///
/// Requests go through the client factory, so the app's network policy and
/// proxy apply. [changes] fires whenever a stored result changes.
class MozhiInstanceChecker {
  new(
    this._clientFor, {
    this.checkTimeout = const Duration(seconds: 8),
    this.testTimeout = const Duration(seconds: 20),
  });

  final MozhiCheckClientFactory _clientFor;

  /// Limit of each request of [check].
  final Duration checkTimeout;

  /// Limit of each request of [test].
  final Duration testTimeout;

  /// Engines [test] prefers, in this order; otherwise it takes the first
  /// one the instance lists.
  static const testEngineOrder = [
    'google',
    'duckduckgo',
    'libre',
    'mymemory',
    'yandex',
    'reverso',
    'deepl',
  ];

  /// What [test] translates, and from and to which language.
  static const testText = 'hello';
  static const testSource = 'en';
  static const testTarget = 'de';

  final Map<String, InstanceHealth> _results = {};
  final StreamController<void> _changes = StreamController.broadcast();

  /// The stored results by instance URL.
  Map<String, InstanceHealth> get results => Map.unmodifiable(_results);

  /// The stored result for [url], or null when it was not checked yet.
  InstanceHealth? resultFor(String url) => _results[url];

  /// Fires after every change of [results].
  Stream<void> get changes => _changes.stream;

  /// Checks the instance at [url] and stores the result.
  Future<InstanceHealth> check(String url) async {
    _store(url, const InstanceChecking());
    final client = _clientFor(Uri.parse(url), checkTimeout);
    final InstanceHealth health;
    try {
      final stopwatch = Stopwatch()..start();
      final engines = await client.getEngines();
      health = InstanceOnline(latency: stopwatch.elapsed, engines: engines);
    } on Object catch (error) {
      return _store(url, InstanceOffline(error));
    } finally {
      client.close();
    }
    return _store(url, health);
  }

  /// Checks all [urls] at the same time.
  Future<void> checkAll(Iterable<String> urls) async {
    await Future.wait(urls.toSet().map(check));
  }

  /// Translates [testText] with the instance at [url]; throws the error
  /// otherwise ([InstanceHasNoEnginesException] when no engine is
  /// enabled). The engine list comes from a stored [InstanceOnline] or is
  /// fetched (and stored) first. [engine] (the Mozhi engine the app uses,
  /// see [mozhiEngineOf]) is tested when the instance lists it; otherwise
  /// [pickTestEngine] chooses.
  Future<InstanceTestResult> test(String url, {String? engine}) async {
    final client = _clientFor(Uri.parse(url), testTimeout);
    try {
      var engines = switch (_results[url]) {
        InstanceOnline(:final engines) => engines,
        _ => null,
      };
      if (engines == null) {
        final stopwatch = Stopwatch()..start();
        try {
          engines = await client.getEngines();
        } on Object catch (error) {
          _store(url, InstanceOffline(error));
          rethrow;
        }
        _store(
          url,
          InstanceOnline(latency: stopwatch.elapsed, engines: engines),
        );
      }
      final tested = engine != null && engines.containsKey(engine)
          ? engine
          : pickTestEngine(engines);
      if (tested == null) throw const InstanceHasNoEnginesException();
      final stopwatch = Stopwatch()..start();
      final translation = await client.translate(
        engine: tested,
        from: testSource,
        to: testTarget,
        text: testText,
      );
      return InstanceTestResult(
        engineId: tested,
        engineName: engines[tested] ?? tested,
        text: translation.translatedText,
        latency: stopwatch.elapsed,
      );
    } finally {
      client.close();
    }
  }

  /// The engine [test] uses from [engines]: the first of [testEngineOrder]
  /// that is there, else the first listed, else null.
  static String? pickTestEngine(Map<String, String> engines) {
    for (final id in testEngineOrder) {
      if (engines.containsKey(id)) return id;
    }
    return engines.keys.firstOrNull;
  }

  /// Forgets every stored result.
  void clear() {
    if (_results.isEmpty) return;
    _results.clear();
    _notify();
  }

  /// Stops [changes]; the stored results stay readable.
  Future<void> dispose() => _changes.close();

  T _store<T extends InstanceHealth>(String url, T health) {
    _results[url] = health;
    _notify();
    return health;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
