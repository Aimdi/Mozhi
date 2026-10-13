import 'dart:async';

import 'package:collection/collection.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/models/models.dart';

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
/// Requests that every instance would reject are rethrown immediately:
/// HTTP 400/413/414/431 and Mozhi's input errors, which the real server
/// reports as 500 (an invalid language code, an unknown engine, a missing
/// parameter, an engine without TTS), see [isInputError].
///
/// Every `MozhiApiException` that leaves [run] or [withClient] has its
/// message sanitised ([sanitize]): Mozhi forwards raw Go errors that
/// contain upstream URLs whose query strings carry the user's text.
class MozhiPool {
  new(this._builder);

  final MozhiClientBuilder _builder;
  final Map<String, MozhiApiClient> _clients = {};
  List<MozhiInstance> _instances = const [];
  MozhiInstance? _preferred;

  /// The configured instances, in failover order.
  List<MozhiInstance> get instances => _instances;

  /// The instance requests start at, or null when none is configured.
  MozhiInstance? get active => _preferred ?? _instances.firstOrNull;

  /// Replaces the instance list. Closes clients of removed instances.
  ///
  /// The order is the user's preference, so any change to the URL order
  /// (reordering, adding or removing an instance) forgets the instance a
  /// failover picked: the next request starts at the first instance again.
  /// A label-only change keeps it.
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

  /// Forgets the instance a failover picked, so the next request starts at
  /// the first configured instance again.
  void resetPreferred() => _preferred = null;

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
  /// Throws a `MozhiApiException` when no instance is configured, and the
  /// last failover-eligible error when every instance failed.
  Future<T> run<T>(
    MozhiAction<T> action, {
    bool failOverOnTimeout = true,
  }) async {
    final tried = <String>{};
    Object? lastError;
    StackTrace? lastStackTrace;
    MozhiInstance? previous;
    while (true) {
      final instance = _next(previous, tried);
      if (instance == null) break;
      tried.add(instance.url);
      previous = instance;
      try {
        final result = await action(_clientFor(instance), instance);
        if (_isConfigured(instance)) _preferred = instance;
        return result;
      } on MozhiApiException catch (error, stackTrace) {
        final sanitized = sanitize(error);
        if (!canFailOver(error, failOverOnTimeout: failOverOnTimeout)) {
          Error.throwWithStackTrace(sanitized, stackTrace);
        }
        lastError = sanitized;
        lastStackTrace = stackTrace;
      } on TimeoutException catch (error, stackTrace) {
        if (!failOverOnTimeout) rethrow;
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace!);
    }
    throw const MozhiApiException('No Mozhi instance is configured.');
  }

  /// The next instance to try: the preferred one first, then the instance
  /// after [previous] in the *current* list (so instances added during a
  /// failover are tried too); when [previous] was removed meanwhile, the
  /// search restarts at the active instance. Instances in [tried] are
  /// skipped; null when none is left.
  MozhiInstance? _next(MozhiInstance? previous, Set<String> tried) {
    final instances = _instances;
    if (instances.isEmpty) return null;
    final after = previous == null
        ? -1
        : instances.indexWhere((i) => i.url == previous.url);
    final activeUrl = active?.url;
    final start = after >= 0
        ? after + 1
        : instances.indexWhere((i) => i.url == activeUrl);
    for (var offset = 0; offset < instances.length; offset++) {
      final candidate = instances[(start + offset) % instances.length];
      if (!tried.contains(candidate.url)) return candidate;
    }
    return null;
  }

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

  static final _url = RegExp(
    r'''\b[a-z][a-z0-9+.-]*://[^\s"'<>]+''',
    caseSensitive: false,
  );

  /// See [sanitize].
  static String sanitizeMessage(String message) {
    var text = message.replaceAllMapped(_url, (match) {
      final uri = Uri.tryParse(match[0]!);
      if (uri == null || uri.host.isEmpty) return '<url>';
      return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
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
