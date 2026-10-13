import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

void main() {
  group(MozhiApiException, () {
    group('isRetryable', () {
      const cases = <int?, bool>{
        null: true,
        429: true,
        500: true,
        502: true,
        503: true,
        400: false,
        401: false,
        404: false,
        413: false,
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

      test('labels transport failures without a URI', () {
        expect(
          const MozhiApiException('No response within 30000 ms').toString(),
          'MozhiApiException(network): No response within 30000 ms',
        );
      });
    });
  });
}
