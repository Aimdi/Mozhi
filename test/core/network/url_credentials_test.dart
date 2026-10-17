import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/network/url_credentials.dart';

void main() {
  group('urlCredentials', () {
    test('returns the user-info as written', () {
      expect(
        urlCredentials('https://user:p%40ss@host.example/x'),
        'user:p%40ss',
      );
      expect(urlCredentials('http://user@10.0.0.2:8080'), 'user');
    });

    test('is null without user-info', () {
      expect(urlCredentials('https://host.example'), isNull);
      expect(urlCredentials('https://host.example/a@b'), isNull);
      expect(urlCredentials('https://host.example?to=a@b'), isNull);
      expect(urlCredentials('https://@host.example'), isNull);
      expect(urlCredentials('host.example'), isNull);
      expect(urlCredentials('a@host.example'), isNull);
    });
  });

  group('urlWithoutCredentials', () {
    test('removes the user-info only', () {
      expect(
        urlWithoutCredentials('https://user:pass@Host.example:8443/api?q=1'),
        'https://Host.example:8443/api?q=1',
      );
      expect(
        urlWithoutCredentials('https://@host.example'),
        'https://host.example',
      );
    });

    test('leaves other URLs exactly as they are', () {
      for (final url in [
        'https://Host.example/a@b',
        'http://[fd00::1]:8080',
        'not a url',
      ]) {
        expect(urlWithoutCredentials(url), url);
      }
    });
  });

  group('urlWithCredentials', () {
    test('adds the user-info', () {
      expect(
        urlWithCredentials('https://host.example/api', 'user:pass'),
        'https://user:pass@host.example/api',
      );
    });

    test('replaces existing user-info', () {
      expect(
        urlWithCredentials('https://old@host.example', 'new:pass'),
        'https://new:pass@host.example',
      );
    });

    test('leaves the URL without credentials or a scheme', () {
      expect(
        urlWithCredentials('https://old@host.example', ''),
        'https://host.example',
      );
      expect(urlWithCredentials('host.example', 'user'), 'host.example');
    });
  });
}
