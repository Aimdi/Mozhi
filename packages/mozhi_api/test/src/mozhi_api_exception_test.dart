import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

void main() {
  group(MozhiApiException, () {
    group('isRetryable', () {
      const cases = <int?, bool>{
        null: true,
        // Answers from whatever sits in front of one instance: fail over.
        301: true,
        303: true,
        308: true,
        401: true,
        403: true,
        404: true,
        405: true,
        408: true,
        410: true,
        421: true,
        429: true,
        500: true,
        502: true,
        503: true,
        // Mozhi's validation errors and size limits are the same everywhere.
        400: false,
        413: false,
        414: false,
        431: false,
      };
      cases.forEach((statusCode, retryable) {
        test('is $retryable for ${statusCode ?? 'network errors'}', () {
          expect(
            MozhiApiException('x', statusCode: statusCode).isRetryable,
            retryable,
          );
        });
      });

      const deterministic500s = [
        'Target language code invalid',
        'target language code invalid: xx',
        'Source language code invalid',
        'SOURCE LANGUAGE CODE INVALID',
        'Engine does not exist or has been disabled.',
        'engine does not exist',
        'Engine bing not supported or implemented',
        "Engine deepl doesn't support TTS.",
        'Engine deepl does not support TTS',
      ];
      for (final message in deterministic500s) {
        test('is false for deterministic HTTP 500 "$message"', () {
          expect(
            MozhiApiException(message, statusCode: 500).isRetryable,
            isFalse,
          );
        });
      }

      const retryable500s = [
        'Post "https://translate.googleapis.com/?q=Target language code invalid": EOF',
        'Get "https://deepl.example/?text=Engine does not exist": timeout',
        'ErrTransport: Engine does not exist',
        'runtime error: invalid memory address',
        'Instance has been rate limited',
        'upstream timeout',
      ];
      for (final message in retryable500s) {
        test('stays true for transient/upstream HTTP 500 "$message"', () {
          expect(
            MozhiApiException(message, statusCode: 500).isRetryable,
            isTrue,
          );
        });
      }

      test('keeps network errors retryable regardless of message', () {
        expect(
          const MozhiApiException('Engine does not exist').isRetryable,
          isTrue,
        );
      });
    });

    group('toString', () {
      test('includes the status code and URI', () {
        expect(
          MozhiApiException(
            'Engine does not exist or has been disabled.',
            statusCode: 500,
            uri: Uri.parse('https://mozhi.example/api/engines'),
          ).toString(),
          'MozhiApiException(500): Engine does not exist or has been '
          'disabled. [https://mozhi.example/api/engines]',
        );
      });

      test('leaves credentials out of the URI', () {
        final error = MozhiApiException(
          'Unauthorized',
          statusCode: 401,
          uri: Uri.parse('https://me:p%40ss@mozhi.example/api/version'),
        );

        expect(
          error.toString(),
          'MozhiApiException(401): Unauthorized '
          '[https://mozhi.example/api/version]',
        );
        expect(error.uri!.userInfo, 'me:p%40ss');
      });

      test('leaves the query (user text) out of the URI', () {
        final error = MozhiApiException(
          'Bad gateway',
          statusCode: 502,
          uri: Uri.parse(
            'https://mozhi.example:8443/api/tts?engine=google&text=secret#x',
          ),
        );

        expect(
          error.toString(),
          'MozhiApiException(502): Bad gateway '
          '[https://mozhi.example:8443/api/tts]',
        );
      });

      test('labels transport failures without a URI', () {
        expect(
          const MozhiApiException('No response within 30000 ms').toString(),
          'MozhiApiException(network): No response within 30000 ms',
        );
      });
    });
  });
}
