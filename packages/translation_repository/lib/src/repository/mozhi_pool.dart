import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/repository/instance_health.dart';
import 'package:translation_repository/src/repository/repository_exceptions.dart';

/// Creates a client for one Mozhi instance.
typedef MozhiClientBuilder = MozhiApiClient Function(Uri baseUrl);

/// A request run against one Mozhi instance.
typedef MozhiAction<T> = Future<T> Function(
  MozhiApiClient client,
  MozhiInstance instance,
);

/// Owns one [MozhiApiClient] per configured instance and runs requests with
/// failover across instances.
///
/// Requests start at the preferred instance ([active]); failures another
/// instance might not repeat (network errors, timeouts, 3xx, most 4xx, 429
/// and 5xx, see [canFailOver]) move on to the next instance in
/// configuration order (wrapping around, and picking up instances added
/// while a request is in flight). The instance that answered becomes the
/// preferred one until the configured order changes or
/// [resetPreferred] is called.
///
/// With an [InstanceHealth], servers where a request failed recently (see
/// [canFailOver]) are tried last, here and across launches: requests start
/// at the first server of the user's order that is not cooling down (the
/// preferred one that just answered stays first). Nothing is sent just to
/// check a server; only the outcome of the requests made anyway counts.
///
/// Requests that every instance would reject are rethrown immediately:
/// HTTP 400/413/414/431 and Mozhi's input errors, which the real server
/// reports as 500 (an invalid language code, an unknown engine, a missing
/// parameter, an engine without TTS), see [isInputError].
///
/// Every `MozhiApiException` that leaves [run] or [withClient] has its
/// message sanitised ([sanitize]): Mozhi forwards raw Go errors that
/// contain upstream URLs whose query strings carry the user's text.
class MozhiPool {
  new(this._builder, {this._health});

  final MozhiClientBuilder _builder;
  final InstanceHealth? _health;
  final Map<String, MozhiApiClient> _clients = {};
  List<MozhiInstance> _instances = const [];
  MozhiInstance? _preferred;

  /// Which instances failed recently (null: no such ordering).
  InstanceHealth? get health => _health;

  /// The configured instances, in failover order.
  List<MozhiInstance> get instances => _instances;

  /// The instance requests start at, or null when none is configured: the
  /// first of [startOrder].
  MozhiInstance? get active => startOrder.firstOrNull;

  /// The order the next request tries the instances in: the configured
  /// order starting at the preferred instance (wrapping around), with the
  /// instances the [InstanceHealth] says are cooling down moved to the
  /// back.
  List<MozhiInstance> get startOrder {
    final instances = _instances;
    final preferredUrl = _preferred?.url;
    final start = preferredUrl == null
        ? 0
        : math.max(0, instances.indexWhere((i) => i.url == preferredUrl));
    final rotated = [...instances.skip(start), ...instances.take(start)];
    return _health?.order(rotated) ?? rotated;
  }

  /// Replaces the instance list. Closes clients of removed instances.
  ///
  /// The order is the user's preference, so any change to the URL order
  /// (reordering, adding or removing an instance) forgets the instance a
  /// failover picked: the next request starts at the first instance again.
  /// A label-only change keeps it. When the first instance changes (the
  /// user put another one first), the [InstanceHealth] forgets that
  /// instance's failure, so it is tried first again.
  ///
  /// Returns whether the list changed (URLs, labels or order).
  bool update(List<MozhiInstance> instances) {
    const equality = ListEquality<Object?>();
    final changed = !equality.equals(
      [for (final i in _instances) (i.url, i.label)],
      [for (final i in instances) (i.url, i.label)],
    );
    final reordered = !equality.equals(
      [for (final i in _instances) i.url],
      [for (final i in instances) i.url],
    );
    final previousFirst = _instances.firstOrNull?.url;
    final first = instances.firstOrNull?.url;
    if (previousFirst != null && first != null && first != previousFirst) {
      _health?.forget(first);
    }
    _instances = List.unmodifiable(instances);
    final urls = {for (final instance in instances) instance.url};
    _clients.removeWhere((url, client) {
      if (urls.contains(url)) return false;
      client.close();
      return true;
    });
    final preferredUrl = _preferred?.url;
    _preferred = reordered || preferredUrl == null
        ? null
        : instances.firstWhereOrNull((i) => i.url == preferredUrl);
    return changed;
  }

  /// The user chose [url] to be asked first ("Make preferred", a server
  /// picked to retry with): the [InstanceHealth] forgets its failure and
  /// requests start there (when it is configured), also when it is first
  /// in the list already, which [update] cannot tell from no change at all.
  /// The settings normally move it to the front as well ([update]).
  void prefer(String url) {
    _health?.forget(url);
    final instance = _instances.firstWhereOrNull((i) => i.url == url);
    if (instance != null) _preferred = instance;
  }

  /// Forgets the instance a failover picked, so the next request starts at
  /// the first configured instance again (with [forgetHealth], also every
  /// failure the [InstanceHealth] remembers).
  void resetPreferred({bool forgetHealth = false}) {
    _preferred = null;
    if (forgetHealth) _health?.forget();
  }

  bool _isConfigured(MozhiInstance instance) =>
      _instances.any((i) => i.url == instance.url);

  MozhiApiClient _clientFor(MozhiInstance instance) => _clients.putIfAbsent(
    instance.url,
    () => _builder(Uri.parse(instance.url)),
  );

  /// Runs [action] on the preferred instance, failing over to the others
  /// (see [canFailOver]).
  ///
  /// Pass `failOverOnTimeout: false` for requests that carry user content
  /// (translations, detection, TTS, images): after a timeout the request
  /// may already have reached that server, so it is not sent to another
  /// operator as well (security review W11).
  ///
  /// With [allow], instances it rejects are skipped (the privacy settings
  /// may let the text go to one instance but not to another): the request
  /// is never sent to them, also not as a failover.
  ///
  /// Unless [recordHealth] is false, the [InstanceHealth] learns from each
  /// attempt: a failure that is failed over (see [canFailOver]) marks the
  /// instance failed, an answer marks it working. Only a failure the
  /// server reported ([answeredBy]) is remembered across launches; one that
  /// got no answer (no connection, a timeout: often the device's own
  /// network) counts for this session only. Input errors, cancelled
  /// requests and, with `failOverOnTimeout: false`, timeouts never count:
  /// the server may have the text already, and counting the timeout would
  /// send a retry of the same text to another operator. Pass
  /// `recordHealth: false` for requests whose outcome says nothing about
  /// translating, such as the engine and language lists (a server lists
  /// its engines just as well when its Google engine fails).
  ///
  /// Throws a `MozhiApiException` when no instance is configured, and the
  /// last failover-eligible error when every instance failed; with
  /// [engine], that error wrapped in an [AllInstancesFailedException]
  /// naming [engine], the instances tried and each one's failure
  /// (`AllInstancesFailedException.failures`).
  Future<T> run<T>(
    MozhiAction<T> action, {
    bool failOverOnTimeout = true,
    bool Function(MozhiInstance instance)? allow,
    bool recordHealth = true,
    TranslationEngine? engine,
  }) async {
    final tried = <String>{};
    final attempted = <MozhiInstance>[];
    final failures = <Object>[];
    Object? lastError;
    StackTrace? lastStackTrace;
    while (true) {
      final instance = _next(tried);
      if (instance == null) break;
      tried.add(instance.url);
      if (allow != null && !allow(instance)) continue;
      attempted.add(instance);
      try {
        final result = await action(_clientFor(instance), instance);
        if (_isConfigured(instance)) _preferred = instance;
        if (recordHealth) _health?.markWorked(instance.url);
        return result;
      } on MozhiApiException catch (error, stackTrace) {
        final sanitized = sanitize(error);
        if (!canFailOver(error, failOverOnTimeout: failOverOnTimeout)) {
          Error.throwWithStackTrace(sanitized, stackTrace);
        }
        if (recordHealth) {
          _health?.markFailed(instance.url, persist: answeredBy(error));
        }
        lastError = sanitized;
        lastStackTrace = stackTrace;
        failures.add(sanitized);
      } on TimeoutException catch (error, stackTrace) {
        if (!failOverOnTimeout) rethrow;
        if (recordHealth) _health?.markFailed(instance.url, persist: false);
        lastError = error;
        lastStackTrace = stackTrace;
        failures.add(error);
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(
        engine == null
            ? lastError
            : AllInstancesFailedException.from(
                lastError,
                engine: engine,
                instances: attempted,
                failures: failures,
              ),
        lastStackTrace!,
      );
    }
    throw const MozhiApiException('No Mozhi instance is configured.');
  }

  /// The next instance to try: the first of the *current* [startOrder]
  /// not in [tried] (so instances added during a failover are tried too,
  /// and removed ones are not); null when none is left.
  MozhiInstance? _next(Set<String> tried) =>
      startOrder.firstWhereOrNull((i) => !tried.contains(i.url));

  /// Runs [action] with the cached client of [instance] when it is
  /// configured, else with a temporary client that is closed afterwards.
  /// No failover.
  Future<T> withClient<T>(
    MozhiInstance instance,
    Future<T> Function(MozhiApiClient client) action,
  ) async {
    try {
      if (_isConfigured(instance)) return await action(_clientFor(instance));
      final client = _builder(Uri.parse(instance.url));
      try {
        return await action(client);
      } finally {
        client.close();
      }
    } on MozhiApiException catch (error, stackTrace) {
      Error.throwWithStackTrace(sanitize(error), stackTrace);
    }
  }

  /// Closes every cached client.
  void dispose() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  /// Whether [error] is the server's own answer: an HTTP status, or an
  /// [InstanceDoesNotTranslateException] (it answered without translating).
  /// Not a network error or the client's timeout, which say as much about
  /// the device's connection as about the server.
  static bool answeredBy(MozhiApiException error) =>
      error.statusCode != null || error is InstanceDoesNotTranslateException;

  /// Whether another instance might answer the request that failed with
  /// [error]: `MozhiApiException.isRetryable`, except Mozhi's input errors
  /// ([isInputError]) and, with `failOverOnTimeout: false`, timeouts
  /// ([isTimeout]).
  static bool canFailOver(
    MozhiApiException error, {
    bool failOverOnTimeout = true,
  }) =>
      error.isRetryable &&
      !isInputError(error) &&
      (failOverOnTimeout || !isTimeout(error));

  /// Mozhi's own validation errors. The real server reports them as HTTP
  /// 500 (mozhi-contract G4), so every instance would repeat them:
  /// `Target language code invalid`, `Source language code invalid`,
  /// `Engine does not exist or has been disabled`, `Engine X not supported
  /// or implemented`, `... are required query strings` / `required
  /// arguments`, `... doesn't support TTS ...`, and the image-upload errors.
  ///
  /// Upstream failures (`Post "https://..."`, `Get "..."`,
  /// `ErrTransport: ...`, `runtime error: ...`, rate limits) are not input
  /// errors, even when the user's text in them happens to match.
  static bool isInputError(MozhiApiException error) {
    if (error.statusCode == null) return false;
    final message = error.message.trim();
    if (_upstreamFailure.hasMatch(message)) return false;
    return _inputErrors.any((pattern) => pattern.hasMatch(message));
  }

  static final _upstreamFailure = RegExp(
    r'^(?:(?:Post|Get|Put)\s+"|ErrTransport\b|runtime error\b|instance has been rate limited)',
    caseSensitive: false,
  );

  static final _inputErrors = [
    RegExp('language code invalid', caseSensitive: false),
    RegExp('engine does not exist', caseSensitive: false),
    RegExp('not supported or implemented', caseSensitive: false),
    RegExp("doesn'?t support TTS", caseSensitive: false),
    RegExp(r'\brequired (?:query strings?|arguments?)\b', caseSensitive: false),
    RegExp('no uploaded file associated', caseSensitive: false),
    RegExp('not multipart/form-data', caseSensitive: false),
  ];

  /// Whether [error] is the Mozhi client's request timeout (`No response
  /// within N ms`, no status code). The request may have reached the server.
  static bool isTimeout(MozhiApiException error) =>
      error.statusCode == null &&
      error.message.trimLeft().startsWith('No response within');

  /// [error] with upstream URLs in its message reduced to `scheme://host`
  /// (their paths and query strings can contain the user's text), the
  /// message capped at [maxMessageLength] characters, and the query,
  /// fragment and user info removed from its `uri`. Returns [error] itself
  /// when nothing changes.
  static MozhiApiException sanitize(MozhiApiException error) {
    final message = sanitizeMessage(error.message);
    final uri = error.uri;
    final cleanUri = uri == null ? null : _stripUri(uri);
    if (message == error.message && cleanUri == uri) return error;
    return MozhiApiException(
      message,
      statusCode: error.statusCode,
      uri: cleanUri,
    );
  }

  /// Longest message [sanitize] keeps.
  static const maxMessageLength = 300;

  /// A URL (group 2: `\b[a-z][a-z0-9+.-]*://[^\s"'<>]+`, case-insensitive)
  /// after what precedes it in its run of scheme characters (group 1).
  ///
  /// A run of scheme characters is only tried from its start, and its
  /// scheme starts at the run's first letter that starts a word, so the
  /// run is not scanned again from each later one (`a.b.c.d`): linear
  /// time.
  static final _url = RegExp(
    r'(?<![a-z0-9+.-])((?:[0-9+.-]|\B[a-z])*)'
    r'''(\b[a-z][a-z0-9+.-]*://[^\s"'<>]+)''',
    caseSensitive: false,
  );

  /// See [sanitize].
  static String sanitizeMessage(String message) {
    var text = message.replaceAllMapped(_url, (match) {
      final before = match[1]!;
      final uri = Uri.tryParse(match[2]!);
      if (uri == null || uri.host.isEmpty) return '$before<url>';
      return '$before${uri.scheme}://${uri.host}'
          '${uri.hasPort ? ':${uri.port}' : ''}';
    });
    if (text.length > maxMessageLength) {
      text = '${text.substring(0, maxMessageLength - 1).trimRight()}…';
    }
    return text;
  }

  static Uri _stripUri(Uri uri) {
    if (!uri.hasQuery && !uri.hasFragment && uri.userInfo.isEmpty) return uri;
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    );
  }
}
