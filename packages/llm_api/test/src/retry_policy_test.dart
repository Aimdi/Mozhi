import 'dart:math';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

/// A [Random] whose [nextDouble] always answers [value].
class _FixedRandom implements Random {
  new(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

void main() {
  group(LlmRetryPolicy, () {
    const overloaded = LlmApiException('Overloaded', statusCode: 529);

    LlmRetryPolicy policy({
      int maxRetries = 1,
      double jitter = 0.5,
      Duration baseDelay = const Duration(seconds: 1),
    }) => LlmRetryPolicy(
      maxRetries: maxRetries,
      baseDelay: baseDelay,
      random: _FixedRandom(jitter),
    );

    test('standard retries once and none never', () {
      expect(LlmRetryPolicy.standard.isEnabled, isTrue);
      expect(LlmRetryPolicy.standard.maxRetries, 1);
      expect(LlmRetryPolicy.standard.baseDelay, const Duration(seconds: 1));
      expect(
        LlmRetryPolicy.standard.maxRetryAfter,
        const Duration(seconds: 10),
      );
      expect(LlmRetryPolicy.none.isEnabled, isFalse);
      expect(LlmRetryPolicy.none.delayBefore(1, overloaded), isNull);
      expect(LlmRetryPolicy.standard.delayBefore(1, overloaded), isNotNull);
    });

    test('allows only maxRetries retries', () {
      final twice = policy(maxRetries: 2);
      expect(twice.delayBefore(0, overloaded), isNull);
      expect(twice.delayBefore(1, overloaded), isNotNull);
      expect(twice.delayBefore(2, overloaded), isNotNull);
      expect(twice.delayBefore(3, overloaded), isNull);
    });

    test('retries transient failures only', () {
      final retry = policy();
      for (final error in const [
        LlmApiException('x', statusCode: 400),
        LlmApiException('x', statusCode: 401),
        LlmApiException('x', statusCode: 501),
        LlmApiException('x'),
        LlmRefusalException('no'),
        LlmTruncatedException(),
      ]) {
        expect(retry.delayBefore(1, error), isNull, reason: '$error');
      }
      for (final error in const [
        LlmApiException('x', statusCode: 429),
        LlmApiException('x', statusCode: 503),
        LlmApiException('x', connectionDropped: true),
        LlmInterruptedException(),
      ]) {
        expect(retry.delayBefore(1, error), isNotNull, reason: '$error');
      }
    });

    test('jitters the backoff between half and one and a half times', () {
      expect(
        policy(jitter: 0).delayBefore(1, overloaded),
        const Duration(milliseconds: 500),
      );
      expect(
        policy(jitter: 0.999).delayBefore(1, overloaded),
        const Duration(microseconds: 1499000),
      );
    });

    test('doubles the backoff for every further retry', () {
      final retry = policy(maxRetries: 3);
      expect(retry.delayBefore(1, overloaded), const Duration(seconds: 1));
      expect(retry.delayBefore(2, overloaded), const Duration(seconds: 2));
      expect(retry.delayBefore(3, overloaded), const Duration(seconds: 4));
    });

    test('honours the wait the server asked for, plus a little jitter', () {
      const limited = LlmApiException(
        'Slow down',
        statusCode: 429,
        retryAfter: Duration(seconds: 3),
      );
      expect(
        policy(jitter: 0).delayBefore(1, limited),
        const Duration(seconds: 3),
      );
      expect(
        policy(jitter: 1).delayBefore(1, limited),
        const Duration(milliseconds: 3250),
      );
      expect(
        policy(baseDelay: Duration.zero).delayBefore(1, limited),
        const Duration(seconds: 3),
      );
    });

    test('does not retry when the server asks for a longer wait', () {
      const ten = LlmApiException(
        'x',
        statusCode: 503,
        retryAfter: Duration(seconds: 10),
      );
      const eleven = LlmApiException(
        'x',
        statusCode: 503,
        retryAfter: Duration(seconds: 11),
      );
      expect(policy(jitter: 0).delayBefore(1, ten), ten.retryAfter);
      expect(policy().delayBefore(1, eleven), isNull);
      expect(
        const LlmRetryPolicy(maxRetryAfter: Duration(minutes: 1))
            .delayBefore(1, eleven),
        isNotNull,
      );
    });

    test('uses a shared random source by default', () {
      final delay = LlmRetryPolicy.standard.delayBefore(1, overloaded)!;
      expect(delay, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
      expect(delay, lessThan(const Duration(milliseconds: 1500)));
    });
  });
}
