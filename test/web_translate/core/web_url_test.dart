import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/web_url.dart';

void main() {
  group('normalizeWebUrl', () {
    test('adds https:// when the scheme is missing', () {
      expect(
        normalizeWebUrl('example.com/news/a?b=1'),
        Uri.parse('https://example.com/news/a?b=1'),
      );
      expect(
        normalizeWebUrl('  www.example.org  '),
        Uri.parse('https://www.example.org'),
      );
      expect(
        normalizeWebUrl('//example.com/x'),
        Uri.parse('https://example.com/x'),
      );
      expect(
        normalizeWebUrl('localhost:8080/a'),
        Uri.parse('https://localhost:8080/a'),
      );
    });

    test('keeps http and https and drops the fragment', () {
      expect(
        normalizeWebUrl('http://example.com/a#top'),
        Uri.parse('http://example.com/a'),
      );
      expect(normalizeWebUrl('HTTPS://Example.com'), isNotNull);
    });

    test('accepts IP addresses and internationalised domains', () {
      expect(normalizeWebUrl('192.168.1.10/wiki'), isNotNull);
      expect(normalizeWebUrl('http://[::1]:8080/'), isNotNull);
      expect(normalizeWebUrl('bücher.de'), isNotNull);
    });

    test('takes the first link out of a pasted message', () {
      expect(
        normalizeWebUrl('Look at this: https://example.com/story?id=3 wow'),
        Uri.parse('https://example.com/story?id=3'),
      );
      expect(normalizeWebUrl('no link in here'), isNull);
    });

    test('rejects other schemes and invalid hosts', () {
      for (final input in [
        '',
        '   ',
        'ftp://example.com',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'mailto:someone@example.com',
        'intranet',
        'https://',
        'https://.example.com',
        'https://exa..mple.com',
        'https://-example.com',
        'https://exa_mple.com',
        'http://exa mple.com',
      ]) {
        expect(normalizeWebUrl(input), isNull, reason: input);
      }
    });
  });

  group('isLikelyWebUrl', () {
    test('recognises links and bare domains', () {
      expect(isLikelyWebUrl('https://example.com/a'), isTrue);
      expect(isLikelyWebUrl('example.com'), isTrue);
      expect(isLikelyWebUrl('news.example.co.uk/a/b?c=d'), isTrue);
      expect(isLikelyWebUrl('localhost:3000'), isFalse);
    });

    test('rejects text', () {
      expect(isLikelyWebUrl(''), isFalse);
      expect(isLikelyWebUrl('hello world'), isFalse);
      expect(isLikelyWebUrl('hello'), isFalse);
      expect(isLikelyWebUrl('e.g.'), isFalse);
      expect(isLikelyWebUrl('3.14'), isFalse);
      expect(isLikelyWebUrl('https://'), isFalse);
    });
  });
}
