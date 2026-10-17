import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(DataDestination, () {
    group('forUrl', () {
      test('is self-hosted for this machine and private networks', () {
        for (final url in [
          'http://localhost:11434',
          'http://127.0.0.1:3000',
          'http://192.168.1.20',
          'http://10.0.0.5:5000',
          'http://[fd12:3456::1]:8080',
          'http://nas.local',
          'http://mozhi.lan',
          'http://translateabcdefghij.onion',
          'http://mozhi.i2p',
        ]) {
          final destination = DataDestination.forUrl(url);
          expect(destination, isA<SelfHostedDestination>(), reason: url);
          expect(destination.leavesDevice, isTrue);
          expect(destination.isThirdParty, isFalse);
        }
      });

      test('is a public instance for other servers', () {
        final destination = DataDestination.forUrl(
          'https://mozhi.aryak.me/',
          engine: 'google',
        );
        expect(
          destination,
          const PublicInstanceDestination('mozhi.aryak.me', engine: 'google'),
        );
        expect(destination.isThirdParty, isTrue);
      });

      test('is a cloud provider when named', () {
        final destination = DataDestination.forUrl(
          'https://api.anthropic.com/v1',
          cloudProvider: 'Anthropic',
        );
        expect(
          destination,
          const CloudProviderDestination(
            'Anthropic',
            host: 'api.anthropic.com',
          ),
        );
        expect(destination.isThirdParty, isTrue);
      });

      test('treats a named provider on the LAN as self-hosted', () {
        expect(
          DataDestination.forUrl(
            'http://192.168.1.2:11434',
            cloudProvider: 'Ollama',
          ),
          const SelfHostedDestination('192.168.1.2'),
        );
      });
    });

    test('hostOf handles urls without a scheme and garbage', () {
      expect(DataDestination.hostOf('example.org:8080/x'), 'example.org');
      expect(DataDestination.hostOf('https://a.b/c'), 'a.b');
      expect(DataDestination.hostOf(''), '');
      expect(DataDestination.hostOf('http://[::1'), '');
    });

    test('on device stays on the device', () {
      const destination = OnDeviceDestination();
      expect(destination.isOnDevice, isTrue);
      expect(destination.leavesDevice, isFalse);
      expect(destination.isThirdParty, isFalse);
    });

    test('supports value equality and readable toString', () {
      expect(const OnDeviceDestination(), const OnDeviceDestination());
      expect(
        const OnDeviceDestination().hashCode,
        const OnDeviceDestination().hashCode,
      );
      expect(
        const SelfHostedDestination('a'),
        isNot(const SelfHostedDestination('b')),
      );
      final duplicate = [const SelfHostedDestination('a')];
      expect({
        ...duplicate,
        const SelfHostedDestination('a'),
        const PublicInstanceDestination('a'),
        const PublicInstanceDestination('a', engine: 'x'),
        const CloudProviderDestination('A'),
        const CloudProviderDestination('A', host: 'h'),
      }, hasLength(5));
      expect(const OnDeviceDestination().toString(), 'OnDeviceDestination()');
      expect(
        const SelfHostedDestination('h').toString(),
        'SelfHostedDestination(h)',
      );
      expect(
        const PublicInstanceDestination('h', engine: 'e').toString(),
        'PublicInstanceDestination(h, e)',
      );
      expect(
        const CloudProviderDestination('N', host: 'h').toString(),
        'CloudProviderDestination(N, h)',
      );
    });
  });

  group(ConsentRequiredException, () {
    test('has a readable toString', () {
      expect(
        const ConsentRequiredException(
          kind: ConsentKind.pair,
          destination: PublicInstanceDestination('m.org'),
          engineId: 'mozhi:google',
          source: 'de',
          target: 'en',
        ).toString(),
        'ConsentRequiredException(pair, mozhi:google -> '
        'PublicInstanceDestination(m.org, null), de>en)',
      );
      expect(
        const ConsentRequiredException(
          kind: ConsentKind.offlineOnly,
          destination: CloudProviderDestination('X'),
          engineId: 'ai:x',
        ).toString(),
        'ConsentRequiredException(offlineOnly, ai:x -> '
        'CloudProviderDestination(X, ))',
      );
    });
  });
}
