import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

void main() {
  group(LlmApiException, () {
    test('isRedirect is true for 3xx status codes only', () {
      for (final status in [300, 301, 302, 303, 307, 308, 399]) {
        expect(
          LlmApiException('x', statusCode: status).isRedirect,
          isTrue,
          reason: '$status',
        );
      }
      for (final status in [null, 200, 299, 400, 401, 500]) {
        expect(
          LlmApiException('x', statusCode: status).isRedirect,
          isFalse,
          reason: '$status',
        );
      }
    });

    test('isTruncated and isInterrupted identify the subclasses', () {
      const truncated = LlmTruncatedException(partialText: 'Part');
      const interrupted = LlmInterruptedException(partialText: 'Part');
      const plain = LlmApiException('x');
      const refusal = LlmRefusalException('no');

      expect(truncated.isTruncated, isTrue);
      expect(truncated.isInterrupted, isFalse);
      expect(interrupted.isInterrupted, isTrue);
      expect(interrupted.isTruncated, isFalse);
      for (final exception in [plain, refusal]) {
        expect(exception.isTruncated, isFalse);
        expect(exception.isInterrupted, isFalse);
      }
      expect(truncated.message, LlmTruncatedException.defaultMessage);
      expect(interrupted.message, LlmInterruptedException.defaultMessage);
    });

    test('isStopped identifies LlmStoppedException', () {
      const stopped = LlmStoppedException('stopped', reason: 'OTHER');
      expect(stopped.isStopped, isTrue);
      expect(stopped.unsupportedLanguage, isFalse);
      expect(stopped.isTransient, isFalse);
      expect(
        const LlmStoppedException('x', reason: 'LANGUAGE').unsupportedLanguage,
        isTrue,
      );
      expect(const LlmStoppedException('x').reason, isNull);
      for (final exception in const [
        LlmApiException('x'),
        LlmRefusalException('no'),
        LlmTruncatedException(),
        LlmInterruptedException(),
      ]) {
        expect(exception.isStopped, isFalse, reason: '$exception');
      }
    });

    test('unreachable is false unless the request got no answer', () {
      expect(const LlmApiException('x').unreachable, isFalse);
      expect(const LlmApiException('x', unreachable: true).unreachable, isTrue);
    });

    test('isTransient is true for failures that usually pass', () {
      for (final status in [429, 500, 502, 503, 504, 529]) {
        expect(
          LlmApiException('x', statusCode: status).isTransient,
          isTrue,
          reason: '$status',
        );
      }
      for (final status in [null, 200, 302, 400, 401, 403, 404, 501, 505]) {
        expect(
          LlmApiException('x', statusCode: status).isTransient,
          isFalse,
          reason: '$status',
        );
      }
      expect(
        const LlmApiException('reset', connectionDropped: true).isTransient,
        isTrue,
      );
      expect(const LlmInterruptedException().isTransient, isTrue);
      expect(const LlmTruncatedException().isTransient, isFalse);
      expect(const LlmRefusalException('no').isTransient, isFalse);
    });

    test('a 429 for exhausted credit is not transient', () {
      expect(
        const LlmApiException(
          'You exceeded your current quota',
          statusCode: 429,
          body: '{"error":{"code":"insufficient_quota"}}',
        ).isTransient,
        isFalse,
      );
      expect(
        const LlmApiException(
          'Rate limit reached',
          statusCode: 429,
          body: '{"error":{"code":"rate_limit_exceeded"}}',
        ).isTransient,
        isTrue,
      );
    });

    test('carries the requested wait and defaults', () {
      const plain = LlmApiException('x');
      expect(plain.retryAfter, isNull);
      expect(plain.connectionDropped, isFalse);
      expect(
        const LlmApiException('x', retryAfter: Duration(seconds: 2)).retryAfter,
        const Duration(seconds: 2),
      );
    });

    test('toString shows the status and message', () {
      expect(
        const LlmApiException('Moved', statusCode: 301).toString(),
        'LlmApiException(301): Moved',
      );
      expect(const LlmApiException('x').toString(), 'LlmApiException(-): x');
    });
  });
}
