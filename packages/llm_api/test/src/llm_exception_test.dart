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

    test('toString shows the status and message', () {
      expect(
        const LlmApiException('Moved', statusCode: 301).toString(),
        'LlmApiException(301): Moved',
      );
      expect(const LlmApiException('x').toString(), 'LlmApiException(-): x');
    });
  });
}
