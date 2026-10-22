import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';

void main() {
  group('ShareSecrets', () {
    final secrets = ShareSecrets();

    test('makes 128-bit url-safe tokens', () {
      final tokens = {for (var i = 0; i < 200; i++) secrets.token()};

      expect(tokens, hasLength(200));
      for (final token in tokens) {
        expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      }
    });

    test('makes 64-bit hex ids', () {
      final ids = {for (var i = 0; i < 200; i++) secrets.id()};

      expect(ids, hasLength(200));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      }
    });

    test('makes four-digit PINs', () {
      for (var i = 0; i < 200; i++) {
        expect(secrets.pin(), matches(RegExp(r'^\d{4}$')));
      }
    });

    test('takes its randomness from the generator it is given', () {
      expect(ShareSecrets(Random(1)).token(), ShareSecrets(Random(1)).token());
      expect(ShareSecrets(Random(1)).pin(), ShareSecrets(Random(1)).pin());
    });
  });

  group('constantTimeEquals', () {
    test('compares strings', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'ab'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('ShareRateLimiter', () {
    test('allows max events per window and key', () {
      var now = DateTime(2026);
      final limiter = ShareRateLimiter(
        max: 2,
        per: const Duration(minutes: 1),
        clock: () => now,
      );

      expect(limiter.allow('a'), isTrue);
      expect(limiter.allows('a'), isTrue);
      expect(limiter.allow('a'), isTrue);
      expect(limiter.allows('a'), isFalse);
      expect(limiter.allow('a'), isFalse);
      expect(limiter.allow('b'), isTrue);

      now = now.add(const Duration(seconds: 61));
      expect(limiter.allow('a'), isTrue);
    });

    test('forgets quiet keys', () {
      var now = DateTime(2026);
      final limiter = ShareRateLimiter(
        max: 1,
        per: const Duration(seconds: 1),
        clock: () => now,
      );
      for (var i = 0; i < 600; i++) {
        limiter.allow('$i');
      }

      now = now.add(const Duration(seconds: 2));
      expect(limiter.allow('new'), isTrue);
      expect(limiter.allow('0'), isTrue);
    });
  });
}
