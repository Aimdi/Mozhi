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
/// Requests start at the preferred instance ([active]); retryable failures
/// (`MozhiApiException.isRetryable`, [TimeoutException]) move on to the next
/// instance in configuration order (wrapping around). The instance that
/// answered becomes the preferred one. Non-retryable failures (4xx such as
/// an unsupported language) are rethrown immediately.
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

  /// Replaces the instance list. Closes clients of removed instances and
  /// forgets the preferred instance when it was removed.
  ///
  /// Returns whether the list changed (URLs, labels or order).
  bool update(List<MozhiInstance> instances) {
    final changed = !const ListEquality<(String, String?)>().equals(
      [for (final i in _instances) (i.url, i.label)],
      [for (final i in instances) (i.url, i.label)],
    );
    _instances = List.unmodifiable(instances);
    final urls = {for (final instance in instances) instance.url};
    _clients.removeWhere((url, client) {
      if (urls.contains(url)) return false;
      client.close();
      return true;
    });
    final preferredUrl = _preferred?.url;
    _preferred = preferredUrl == null
        ? null
        : instances.firstWhereOrNull((i) => i.url == preferredUrl);
    return changed;
  }

  bool _isConfigured(MozhiInstance instance) =>
      _instances.any((i) => i.url == instance.url);

  MozhiApiClient _clientFor(MozhiInstance instance) => _clients.putIfAbsent(
    instance.url,
    () => _builder(Uri.parse(instance.url)),
  );

  /// Runs [action] on the preferred instance, failing over to the others.
  ///
  /// Throws a `MozhiApiException` when no instance is configured, and the
  /// last retryable error when every instance failed.
  Future<T> run<T>(MozhiAction<T> action) async {
    final instances = _instances;
    final start = instances.indexOf(active ?? _noInstance);
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var offset = 0; offset < instances.length; offset++) {
      final instance = instances[(start + offset) % instances.length];
      // The configuration may change while a failover is in progress.
      if (!_isConfigured(instance)) continue;
      try {
        final result = await action(_clientFor(instance), instance);
        if (_isConfigured(instance)) _preferred = instance;
        return result;
      } on MozhiApiException catch (error, stackTrace) {
        if (!error.isRetryable) rethrow;
        lastError = error;
        lastStackTrace = stackTrace;
      } on TimeoutException catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace!);
    }
    throw const MozhiApiException('No Mozhi instance is configured.');
  }

  /// Runs [action] with the cached client of [instance] when it is
  /// configured, else with a temporary client that is closed afterwards.
  /// No failover.
  Future<T> withClient<T>(
    MozhiInstance instance,
    Future<T> Function(MozhiApiClient client) action,
  ) async {
    if (_isConfigured(instance)) return await action(_clientFor(instance));
    final client = _builder(Uri.parse(instance.url));
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  /// Closes every cached client.
  void dispose() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  static const _noInstance = MozhiInstance(url: '');
}
