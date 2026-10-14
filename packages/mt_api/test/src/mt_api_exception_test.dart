import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

void main() {
  group(MtErrorKind, () {
    test('fromStatus', () {
      const table = {
        400: MtErrorKind.badRequest,
        401: MtErrorKind.unauthorized,
        403: MtErrorKind.unauthorized,
        404: MtErrorKind.notFound,
        413: MtErrorKind.payloadTooLarge,
        414: MtErrorKind.payloadTooLarge,
        429: MtErrorKind.rateLimited,
        529: MtErrorKind.rateLimited,
        456: MtErrorKind.quotaExceeded,
        500: MtErrorKind.server,
        502: MtErrorKind.server,
        599: MtErrorKind.server,
        600: MtErrorKind.unknown,
        302: MtErrorKind.unknown,
        418: MtErrorKind.unknown,
      };
      for (final MapEntry(key: status, value: kind) in table.entries) {
        expect(MtErrorKind.fromStatus(status), kind, reason: '$status');
      }
    });
  });

  group(MtApiException, () {
    test('defaults', () {
      const e = MtApiException('Boom');
      expect(e.kind, MtErrorKind.unknown);
      expect(e.statusCode, isNull);
      expect(e.detail, isNull);
      expect(e.uri, isNull);
      expect(e.fullMessage, 'Boom');
      expect(e.toString(), 'MtApiException(unknown): Boom');
    });

    test('isRetryable', () {
      const retryable = {
        MtErrorKind.network,
        MtErrorKind.timeout,
        MtErrorKind.rateLimited,
        MtErrorKind.server,
      };
      for (final kind in MtErrorKind.values) {
        expect(
          MtApiException('x', kind: kind).isRetryable,
          retryable.contains(kind),
          reason: kind.name,
        );
      }
    });

    test('fullMessage appends a detail that adds information', () {
      expect(
        const MtApiException('Failed.', detail: ' Server down ').fullMessage,
        'Failed. (Server down)',
      );
      expect(
        const MtApiException('Failed.', detail: '  ').fullMessage,
        'Failed.',
      );
      expect(
        const MtApiException('Quota exceeded.', detail: 'Quota').fullMessage,
        'Quota exceeded.',
      );
    });

    test('toString includes status, detail and URI', () {
      final e = MtApiException(
        'Too many requests.',
        kind: MtErrorKind.rateLimited,
        statusCode: 429,
        detail: 'slow down',
        uri: Uri.parse('https://api.deepl.com/v2/translate'),
      );
      expect(
        e.toString(),
        'MtApiException(429): Too many requests. (slow down) '
        '[https://api.deepl.com/v2/translate]',
      );
    });

    test('toString leaves credentials and the query out of the URI', () {
      final e = MtApiException(
        'Failed.',
        statusCode: 500,
        uri: Uri.parse('https://me:secret@mt.example:8443/translate?q=hi#x'),
      );
      expect(
        e.toString(),
        'MtApiException(500): Failed. [https://mt.example:8443/translate]',
      );
      expect(e.toString(), isNot(contains('secret')));
    });

    test('subclasses name themselves', () {
      const deepl = DeeplApiException(
        'Quota exceeded.',
        kind: MtErrorKind.quotaExceeded,
        statusCode: 456,
      );
      const libre = LibreTranslateException(
        'Offline.',
        kind: MtErrorKind.network,
      );
      expect(deepl, isA<MtApiException>());
      expect(libre, isA<MtApiException>());
      expect(deepl.toString(), 'DeeplApiException(456): Quota exceeded.');
      expect(libre.toString(), 'LibreTranslateException(network): Offline.');
    });
  });
}
