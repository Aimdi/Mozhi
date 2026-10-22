import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mozhi/core/privacy/egress/egress_classifier.dart';
import 'package:mozhi/core/privacy/egress/egress_entry.dart';
import 'package:mozhi/core/privacy/egress/egress_failure.dart';
import 'package:mozhi/core/privacy/egress/egress_ledger.dart';

/// An [http.Client] that records every request it sends in [ledger]
/// (see [EgressLedger]): when, the method, the destination and purpose
/// ([classifier]; [purpose] when the caller knows it), whether it went
/// through the proxy (`viaProxy`), the sizes and how it ended.
///
/// The request and the answer pass through unchanged (except for the
/// [purposeHeader], which is removed); only the answer's bytes are counted
/// on their way. Bodies, paths, queries and headers are never recorded.
class EgressRecordingClient extends http.BaseClient {
  new(
    this._inner, {
    required this.ledger,
    this.purpose,
    this.classifier = const EgressClassifier(),
    bool Function(String host)? viaProxy,
    this.closesInner = true,
  }) : _viaProxy = viaProxy ?? _never;

  final http.Client _inner;
  final EgressLedger ledger;

  /// The purpose of every request (null: guessed by [classifier]).
  final EgressPurpose? purpose;
  final EgressClassifier classifier;
  final bool Function(String host) _viaProxy;

  /// Whether [close] closes the wrapped client.
  final bool closesInner;

  static bool _never(String host) => false;

  /// A request header naming the [EgressPurpose] of that request (set by
  /// an `EgressPurposeClient` above this client); it overrides [purpose]
  /// and the guess, and is removed before the request is sent.
  static const purposeHeader = 'x-mozhi-egress-purpose';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    final method = _methodOf(request.method);
    // BaseRequest.headers ignores the case of names.
    final tagged = EgressPurpose.values
        .asNameMap()[request.headers.remove(purposeHeader)];
    final (destination, why) = classifier.classify(
      url,
      method: method,
      purpose: tagged ?? purpose,
    );
    var entry = ledger.begin(
      method: method,
      scheme: url.scheme.toLowerCase(),
      destination: destination,
      purpose: why,
      viaProxy: _viaProxy(destination.host),
      bytesSent: bytesSentOf(request),
    );
    final stopwatch = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } on Object catch (error) {
      final outcome = egressOutcomeOf(error);
      ledger.update(
        entry.copyWith(
          outcome: outcome,
          failure: outcome == EgressOutcome.failed
              ? egressFailureOf(error)
              : null,
          duration: stopwatch.elapsed,
        ),
      );
      rethrow;
    }

    final status = response.statusCode;
    final finalUrl = response is http.BaseResponseWithUrl
        ? (response as http.BaseResponseWithUrl).url
        : null;
    final finalHost = finalUrl == null
        ? null
        : EgressClassifier.normalizeHost(finalUrl.host);
    entry = entry.copyWith(
      statusCode: status,
      redirectedTo: finalHost != null && finalHost != destination.host
          ? finalHost
          : null,
    );
    ledger.update(entry);

    var received = 0;
    var finished = false;
    void finish(EgressOutcome outcome, {Object? error}) {
      if (finished) return;
      finished = true;
      ledger.update(
        entry.copyWith(
          bytesReceived: received,
          outcome: outcome,
          failure: outcome == EgressOutcome.failed && error != null
              ? egressFailureOf(error)
              : null,
          duration: stopwatch.elapsed,
        ),
      );
    }

    final answered = status >= 400
        ? EgressOutcome.httpError
        : EgressOutcome.succeeded;
    final counted = response.stream
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              received += chunk.length;
              sink.add(chunk);
            },
            handleError: (error, stackTrace, sink) {
              final outcome = egressOutcomeOf(error);
              finish(
                outcome == EgressOutcome.notSent
                    ? EgressOutcome.failed
                    : outcome,
                error: error,
              );
              sink.addError(error, stackTrace);
            },
            handleDone: (sink) {
              finish(answered);
              sink.close();
            },
          ),
        )
        .transform(_OnCancel(() => finish(EgressOutcome.cancelled)));

    return finalUrl == null
        ? http.StreamedResponse(
            counted,
            status,
            contentLength: response.contentLength,
            request: response.request,
            headers: response.headers,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase,
          )
        : _StreamedResponseWithUrl(
            counted,
            status,
            url: finalUrl,
            contentLength: response.contentLength,
            request: response.request,
            headers: response.headers,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase,
          );
  }

  @override
  void close() {
    if (closesInner) _inner.close();
  }

  /// The bytes [request] sends: its body (when its size is known in
  /// advance) and its address's path and query (Mozhi's text-to-speech,
  /// for one, sends the text in the query). Headers are not counted.
  static int? bytesSentOf(http.BaseRequest request) {
    final body = request.contentLength ?? (request.method == 'GET' ? 0 : null);
    if (body == null) return null;
    final url = request.url;
    // Both are percent-encoded: one byte per character.
    final target = url.path.length + (url.hasQuery ? url.query.length + 1 : 0);
    return body + target;
  }

  static const _methods = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
    // WebDAV (sync).
    'PROPFIND',
    'MKCOL',
  };

  static String _methodOf(String method) {
    final upper = method.toUpperCase();
    return _methods.contains(upper) ? upper : 'OTHER';
  }
}

/// Calls [onCancel] when the listener cancels before the stream is done.
class _OnCancel extends StreamTransformerBase<List<int>, List<int>> {
  const new(this.onCancel);

  final void Function() onCancel;

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    var done = false;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            done = true;
            unawaited(controller.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        if (!done) onCancel();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }
}

/// A [http.StreamedResponse] that keeps the final [url] of the wrapped one
/// (`BaseResponseWithUrl`, used to resolve redirects).
class _StreamedResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  new(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}
