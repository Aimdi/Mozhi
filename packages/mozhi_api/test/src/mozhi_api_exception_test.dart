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

      test('labels transport failures without a URI', () {
        expect(
          const MozhiApiException('No response within 30000 ms').toString(),
          'MozhiApiException(network): No response within 30000 ms',
        );
      });
    });
  });
}
