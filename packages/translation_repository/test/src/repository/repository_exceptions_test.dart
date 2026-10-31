import 'dart:async';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  group(AllInstancesFailedException, () {
    AllInstancesFailedException failed(
      Object cause, {
      List<Object> failures = const [],
    }) => AllInstancesFailedException.from(
      cause,
      engine: googleEngine,
      instances: [instanceA, instanceB],
      failures: failures,
    );

    group('isRateLimit', () {
      test('is true for HTTP 429', () {
        expect(
          AllInstancesFailedException.isRateLimit(
            const MozhiApiException('nope', statusCode: 429),
          ),
          isTrue,
        );
      });

      for (final message in [
        'request failed with status code: 429',
        'instance has been rate limited',
        'Rate-limited by upstream',
        '429 Too Many Requests',
      ]) {
        test('is true for "$message"', () {
          expect(
            AllInstancesFailedException.isRateLimit(
              MozhiApiException(message, statusCode: 500),
            ),
            isTrue,
          );
        });
      }

      for (final message in [
        'invalid json',
        'request failed with status code: 4290',
        'Get "https://translate.google.com": EOF',
      ]) {
        test('is false for "$message"', () {
          expect(
            AllInstancesFailedException.isRateLimit(
              MozhiApiException(message, statusCode: 500),
            ),
            isFalse,
          );
        });
      }

      test('is false for other errors', () {
        expect(
          AllInstancesFailedException.isRateLimit(
            TimeoutException('rate limited'),
          ),
          isFalse,
        );
      });
    });

    group('rateLimited', () {
      test('is true when any server was rate limited', () {
        final error = failed(
          const MozhiApiException('invalid json', statusCode: 500),
          failures: const [
            MozhiApiException(
              'instance has been rate limited',
              statusCode: 500,
            ),
            MozhiApiException('invalid json', statusCode: 500),
          ],
        );
        expect(error.rateLimited, isTrue);
      });

      test('is false when no server was', () {
        final error = failed(
          serverError(),
          failures: [serverError(), serverError('invalid json')],
        );
        expect(error.rateLimited, isFalse);
      });

      test('reads the last failure without the list', () {
        expect(
          failed(
            const MozhiApiException(
              'request failed with status code: 429',
              statusCode: 500,
            ),
          ).rateLimited,
          isTrue,
        );
        expect(failed(serverError()).rateLimited, isFalse);
      });

      test('reads its own message without a cause', () {
        const error = AllInstancesFailedException(
          'request failed with status code: 429',
          engine: TranslationEngine(
            id: 'mozhi:google',
            kind: EngineKind.mozhi,
            name: 'Google',
          ),
          instances: [],
          statusCode: 500,
        );
        expect(error.rateLimited, isTrue);
        expect(error.serverAnswered, isTrue);
      });
    });

    group('serverAnswered', () {
      test('is true when a server answered with an error', () {
        expect(
          failed(
            TimeoutException('slow'),
            failures: [serverError(), TimeoutException('slow')],
          ).serverAnswered,
          isTrue,
        );
      });

      test('is false when no server answered', () {
        expect(
          failed(
            const MozhiApiException('Connection refused'),
            failures: [
              const MozhiApiException('Connection refused'),
              TimeoutException('slow'),
            ],
          ).serverAnswered,
          isFalse,
        );
        expect(failed(TimeoutException('slow')).serverAnswered, isFalse);
      });
    });

    test('from keeps the failures unmodifiable', () {
      final error = failed(serverError(), failures: [serverError()]);
      expect(() => error.failures.add(serverError()), throwsUnsupportedError);
    });
  });
}
