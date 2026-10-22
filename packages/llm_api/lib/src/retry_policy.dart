import 'dart:math';

import 'package:llm_api/src/llm_exception.dart';
import 'package:meta/meta.dart';

/// When and how `LlmClient.streamChat` sends a request again after a
/// transient failure ([LlmApiException.isTransient]: rate limits, server
/// errors, "overloaded", dropped connections).
///
/// The clients only ever retry before the first text delta arrived, so that
/// visible output is never paid for twice; a failure after that is reported
/// as it is. Cancelling the stream also cancels a pending retry at once.
///
/// [standard] (the default of every client) retries once; [none] never
/// does.
@immutable
class LlmRetryPolicy {
  const new({
    this.maxRetries = 1,
    this.baseDelay = const Duration(seconds: 1),
    this.maxRetryAfter = const Duration(seconds: 10),
    this.random,
  });

  /// Retries once, after about a second or the wait the server asked for
  /// (up to [maxRetryAfter]).
  static const standard = LlmRetryPolicy();

  /// Never retries.
  static const none = LlmRetryPolicy(maxRetries: 0);

  /// How many times one request may be sent again.
  final int maxRetries;

  /// The wait before the first retry when the server did not ask for one;
  /// it doubles for every further retry. Each wait is jittered between half
  /// and one and a half times its length, so that parallel requests (the
  /// parts of a long text) do not retry in lockstep.
  final Duration baseDelay;

  /// The longest server-requested wait ([LlmApiException.retryAfter]) that
  /// is honoured. When a server asks for longer, the request is not retried
  /// at all: waiting less would most likely fail again, and waiting that
  /// long would keep the user waiting for an answer that an error (and
  /// another engine) gives sooner.
  final Duration maxRetryAfter;

  /// The source of the jitter; a shared [Random] when null.
  final Random? random;

  static final _random = Random();

  /// Whether this policy ever retries.
  bool get isEnabled => maxRetries > 0;

  /// How long to wait before retry number [retry] (1 for the first) after
  /// [error], or null when the request must not be sent again: [retry] is
  /// beyond [maxRetries], [error] is not transient, or the server asked for
  /// a wait longer than [maxRetryAfter].
  ///
  /// A server-requested wait is honoured exactly, plus up to a quarter of
  /// [baseDelay] of jitter.
  Duration? delayBefore(int retry, LlmApiException error) {
    if (retry < 1 || retry > maxRetries || !error.isTransient) return null;
    final jitter = (random ?? _random).nextDouble();
    if (error.retryAfter case final wait?) {
      if (wait > maxRetryAfter) return null;
      return wait + baseDelay * (jitter / 4);
    }
    final backoff = baseDelay * (1 << min(retry - 1, 16));
    return backoff * (0.5 + jitter);
  }
}
