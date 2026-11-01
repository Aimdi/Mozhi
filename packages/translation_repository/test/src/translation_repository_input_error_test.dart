import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('TranslationRepository.isMozhiInputError', () {
    test("is true for Mozhi's validation errors", () {
      for (final message in [
        'Target language code invalid',
        'Source language code invalid',
        'Engine does not exist or has been disabled',
      ]) {
        expect(
          TranslationRepository.isMozhiInputError(
            MozhiApiException(message, statusCode: 500),
          ),
          isTrue,
          reason: message,
        );
      }
    });

    test('is false for server failures and other errors', () {
      for (final error in <Object?>[
        const MozhiApiException(
          'request failed with status code: 429',
          statusCode: 500,
        ),
        const MozhiApiException('Target language code invalid'),
        const LlmApiException('Target language code invalid'),
        StateError('x'),
        null,
      ]) {
        expect(
          TranslationRepository.isMozhiInputError(error),
          isFalse,
          reason: '$error',
        );
      }
    });
  });
}
