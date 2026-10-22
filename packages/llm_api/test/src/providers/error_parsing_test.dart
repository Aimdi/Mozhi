import 'dart:convert';

import 'package:llm_api/src/providers/error_parsing.dart';
import 'package:test/test.dart';

void main() {
  group('retryAfterFrom', () {
    final now = DateTime.utc(2026, 10, 22, 8);
    DateTime clock() => now;

    Duration? parse(Map<String, String> headers, [Object? json]) =>
        retryAfterFrom(headers, json, now: clock);

    test('reads retry-after-ms first', () {
      expect(
        parse({'retry-after-ms': '1500', 'retry-after': '9'}),
        const Duration(milliseconds: 1500),
      );
      expect(
        parse({'Retry-After-Ms': ' 20.5 '}),
        const Duration(microseconds: 20500),
      );
    });

    test('reads Retry-After in seconds, in any case', () {
      expect(parse({'Retry-After': '7'}), const Duration(seconds: 7));
      expect(parse({'retry-after': '0.25'}), const Duration(milliseconds: 250));
      expect(parse({'RETRY-AFTER': '-3'}), Duration.zero);
    });

    test('reads Retry-After as an HTTP date', () {
      expect(
        parse({'retry-after': 'Thu, 22 Oct 2026 08:00:30 GMT'}),
        const Duration(seconds: 30),
      );
      expect(
        parse({'retry-after': 'Thu, 22 Oct 2026 07:59:00 GMT'}),
        Duration.zero,
      );
    });

    test('ignores values it cannot read', () {
      for (final value in [
        '',
        'soon',
        'NaN',
        'Infinity',
        'Thu, 22 Foo 2026 08:00:30 GMT',
        '22 Oct 2026 08:00:30 GMT',
      ]) {
        expect(parse({'retry-after': value}), isNull, reason: value);
      }
      expect(parse({'retry-after-ms': 'x', 'retry-after': '2'}), isNotNull);
      expect(parse(const {}), isNull);
    });

    test('caps absurd waits at a day', () {
      expect(parse({'retry-after': '1e12'}), const Duration(days: 1));
    });

    test('reads a Gemini RetryInfo from the body', () {
      final json = {
        'error': {
          'code': 429,
          'details': [
            {'@type': 'type.googleapis.com/google.rpc.QuotaFailure'},
            {'@type': 'type.googleapis.com/google.rpc.RetryInfo'},
            {
              '@type': 'type.googleapis.com/google.rpc.RetryInfo',
              'retryDelay': '13s',
            },
          ],
        },
      };
      expect(parse(const {}, json), const Duration(seconds: 13));
      expect(
        parse(const {}, {
          'error': {
            'details': [
              {'retryDelay': '1.5s'},
            ],
          },
        }),
        const Duration(milliseconds: 1500),
      );
      expect(
        parse(const {}, {
          'error': {
            'details': [
              {'retryDelay': '2m'},
              {'retryDelay': 'xs'},
            ],
          },
        }),
        isNull,
      );
      // Headers win over the body.
      expect(parse({'retry-after': '1'}, json), const Duration(seconds: 1));
    });
  });

  group('httpError', () {
    test('carries the wait from headers or body', () {
      expect(
        httpError(429, '', null, headers: {'retry-after': '4'}).retryAfter,
        const Duration(seconds: 4),
      );
      expect(
        httpError(
          429,
          jsonEncode({
            'error': {
              'message': 'Quota',
              'details': [
                {'retryDelay': '6s'},
              ],
            },
          }),
          null,
        ).retryAfter,
        const Duration(seconds: 6),
      );
      expect(httpError(503, '', 'Unavailable').retryAfter, isNull);
    });
  });
}
