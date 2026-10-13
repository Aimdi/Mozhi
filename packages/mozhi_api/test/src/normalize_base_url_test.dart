import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

void main() {
  group('MozhiApiClient.normalizeBaseUrl', () {
    group('infers https for public hosts', () {
      const cases = {
        'mozhi.aryak.me': 'https://mozhi.aryak.me',
        '  mozhi.aryak.me/  ': 'https://mozhi.aryak.me',
        'translate.example.com:8443/mozhi':
            'https://translate.example.com:8443/mozhi',
        '8.8.8.8': 'https://8.8.8.8',
        '172.15.0.1': 'https://172.15.0.1',
        '172.32.0.1': 'https://172.32.0.1',
        '100.63.0.1': 'https://100.63.0.1',
        '100.128.0.1': 'https://100.128.0.1',
        '192.169.1.1': 'https://192.169.1.1',
        '10.example.com': 'https://10.example.com',
        '[2001:db8::1]': 'https://[2001:db8::1]',
        'mozhi.local.example.com': 'https://mozhi.local.example.com',
      };
      cases.forEach((input, expected) {
        test(input, () {
          expect(MozhiApiClient.normalizeBaseUrl(input).toString(), expected);
        });
      });
    });

    group('infers http for hosts that are not publicly routable', () {
      const cases = {
        'localhost': 'http://localhost',
        'localhost:3000': 'http://localhost:3000',
        'LocalHost:3000/': 'http://localhost:3000',
        '127.0.0.1:3000': 'http://127.0.0.1:3000',
        '10.0.0.5': 'http://10.0.0.5',
        '192.168.1.10:3000/mozhi/': 'http://192.168.1.10:3000/mozhi',
        '172.16.0.1': 'http://172.16.0.1',
        '172.31.255.255:3000': 'http://172.31.255.255:3000',
        '169.254.10.20': 'http://169.254.10.20',
        '100.64.0.1': 'http://100.64.0.1',
        '100.127.255.1': 'http://100.127.255.1',
        'raspberrypi:8080': 'http://raspberrypi:8080',
        'mozhi_app:3000': 'http://mozhi_app:3000',
        'mozhi.local': 'http://mozhi.local',
        'Mozhi.Local:3000/api': 'http://mozhi.local:3000',
        'mozhi.localhost': 'http://mozhi.localhost',
        'nas.lan:3000': 'http://nas.lan:3000',
        'mozhi.home.arpa': 'http://mozhi.home.arpa',
        'mozhi.corp.internal': 'http://mozhi.corp.internal',
        'mozhi2xmhqy3m7gnb2sxzyfvrhzkvnfqedfqcaeqg4vzjqbm7l6ksiyd.onion': 'http://mozhi2xmhqy3m7gnb2sxzyfvrhzkvnfqedfqcaeqg4vzjqbm7l6ksiyd.onion',
        'mozhi.i2p': 'http://mozhi.i2p',
        '[::1]:3000': 'http://[::1]:3000',
        '[fd00::5]': 'http://[fd00::5]',
        '[FC00::1]': 'http://[fc00::1]',
        '[fe80::1]': 'http://[fe80::1]',
      };
      cases.forEach((input, expected) {
        test(input, () {
          expect(MozhiApiClient.normalizeBaseUrl(input).toString(), expected);
        });
      });
    });

    group('canonicalises URLs with a scheme', () {
      const cases = {
        // An explicit scheme always wins over inference.
        'http://mozhi.example.com': 'http://mozhi.example.com',
        'https://192.168.1.10:3000': 'https://192.168.1.10:3000',
        'HTTPS://Mozhi.Aryak.ME': 'https://mozhi.aryak.me',
        // Trailing slashes and a trailing /api segment.
        'https://mozhi.aryak.me/': 'https://mozhi.aryak.me',
        'https://mozhi.aryak.me/api': 'https://mozhi.aryak.me',
        'https://mozhi.aryak.me/api/': 'https://mozhi.aryak.me',
        'https://mozhi.aryak.me///': 'https://mozhi.aryak.me',
        'https://h.example/mozhi/api//': 'https://h.example/mozhi',
        'https://h.example/api/api': 'https://h.example/api',
        'https://h.example/apis': 'https://h.example/apis',
        'https://h.example//sub//path//': 'https://h.example/sub/path',
        'https://h.example/My%20Mozhi/': 'https://h.example/My%20Mozhi',
        'h.example/my mozhi/?': 'https://h.example/my%20mozhi',
        // Query and fragment (e.g. a pasted web UI link) are dropped.
        'https://mozhi.aryak.me/?engine=google&from=auto&to=en&text=hi':
            'https://mozhi.aryak.me',
        'https://h.example:8443/sub/api/?x=1#top': 'https://h.example:8443/sub',
        // Default ports are implied; others are kept.
        'https://mozhi.aryak.me:443': 'https://mozhi.aryak.me',
        'http://mozhi.example.com:80/': 'http://mozhi.example.com',
        'http://mozhi.example.com:443': 'http://mozhi.example.com:443',
        // Credentials for instances behind basic auth.
        'https://me:secret@mozhi.example.com/':
            'https://me:secret@mozhi.example.com',
        '\t\nhttps://mozhi.aryak.me\n': 'https://mozhi.aryak.me',
      };
      cases.forEach((input, expected) {
        test(input, () {
          expect(MozhiApiClient.normalizeBaseUrl(input).toString(), expected);
        });
      });
    });

    test('returns the parts the client relies on', () {
      final url = MozhiApiClient.normalizeBaseUrl('192.168.1.10:3000/mozhi');

      expect(url.scheme, 'http');
      expect(url.host, '192.168.1.10');
      expect(url.port, 3000);
      expect(url.pathSegments, ['mozhi']);
      expect(url.hasQuery, isFalse);
      expect(url.hasFragment, isFalse);
    });

    test('is idempotent', () {
      for (final input in [
        'mozhi.aryak.me',
        'localhost:3000/mozhi/api/',
        'https://me:pw@h.example:8443/a/b?c#d',
        '[fd00::5]:3000',
      ]) {
        final once = MozhiApiClient.normalizeBaseUrl(input);
        expect(MozhiApiClient.normalizeBaseUrl(once.toString()), once);
      }
    });

    group('rejects input that cannot be an instance URL', () {
      for (final input in [
        '',
        '   ',
        'not a url',
        'https://exa mple.com',
        'https://',
        'https:///mozhi',
        '//',
        'ftp://mozhi.example.com',
        'ws://mozhi.example.com',
        'https://mozhi.example.com:abc',
        'https://mozhi.example.com:0',
        'https://mozhi.example.com:65536',
        'https://mozhi..example.com',
        'https://.example.com',
        'https://bücher.example',
        'https://mozhi.example.com​',
      ]) {
        test('"$input"', () {
          expect(
            () => MozhiApiClient.normalizeBaseUrl(input),
            throwsFormatException,
          );
        });
      }
    });
  });
}
