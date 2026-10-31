import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  tearDown(TailnetHosts.forget);

  group('TailnetHosts', () {
    test('isTailnetName', () {
      expect(TailnetHosts.isTailnetName('nas.tail123.ts.net'), isTrue);
      expect(TailnetHosts.isTailnetName('NAS.tail123.TS.NET.'), isTrue);
      expect(TailnetHosts.isTailnetName('ts.net'), isTrue);
      expect(TailnetHosts.isTailnetName('ts.network.example'), isFalse);
      expect(TailnetHosts.isTailnetName('nots.net'), isFalse);
      expect(TailnetHosts.isTailnetName('example.org'), isFalse);
    });

    test('a name is public until a lookup showed Tailscale addresses', () {
      const host = 'nas.tail123.ts.net';
      expect(TailnetHosts.isKnown(host), isFalse);
      expect(TailnetHosts.isPrivate(host), isFalse);
      expect(DataDestination.isPrivateHost(host), isFalse);

      TailnetHosts.record(host, ['100.64.0.1', 'fd7a:115c:a1e0::1']);
      expect(TailnetHosts.isKnown(host), isTrue);
      expect(TailnetHosts.isPrivate(host), isTrue);
      expect(TailnetHosts.isPrivate('Nas.Tail123.ts.net.'), isTrue);
      expect(DataDestination.isPrivateHost(host), isTrue);
      expect(
        DataDestination.forUrl('http://$host:3000'),
        const SelfHostedDestination(host),
      );

      TailnetHosts.forget(host);
      expect(TailnetHosts.isKnown(host), isFalse);
      expect(DataDestination.isPrivateHost(host), isFalse);
    });

    test('a Funnel name (public relays) stays public', () {
      const host = 'app.tail123.ts.net';
      for (final addresses in [
        ['198.51.100.7'],
        ['100.64.0.1', '198.51.100.7'],
        ['2001:db8::1'],
        <String>[],
      ]) {
        TailnetHosts.record(host, addresses);
        expect(TailnetHosts.isKnown(host), isTrue, reason: '$addresses');
        expect(TailnetHosts.isPrivate(host), isFalse, reason: '$addresses');
        expect(
          DataDestination.forUrl('https://$host'),
          const PublicInstanceDestination(host),
        );
      }
    });

    test('ignores names outside ts.net', () {
      TailnetHosts.record('example.org', ['100.64.0.1']);
      expect(TailnetHosts.isKnown('example.org'), isFalse);
      expect(DataDestination.isPrivateHost('example.org'), isFalse);
    });

    test('isTailscaleAddress', () {
      for (final address in [
        '100.64.0.0',
        '100.100.100.100',
        '100.127.255.255',
        'fd7a:115c:a1e0::',
        'fd7a:115c:a1e0::53',
        'FD7A:115C:A1E0:AB12:4843:CD96:6258:B240',
        '[fd7a:115c:a1e0::1]',
        'fd7a:115c:a1e0::1%tailscale0',
        '::ffff:100.64.1.2',
        '::ffff:6440:0102',
      ]) {
        expect(
          TailnetHosts.isTailscaleAddress(address),
          isTrue,
          reason: address,
        );
      }
      for (final address in [
        '100.63.255.255',
        '100.128.0.0',
        '10.0.0.1',
        '192.168.1.1',
        '8.8.8.8',
        'fd7a:115c:a1e1::1',
        'fd7a:115c::a1e0',
        'fd00::1',
        '::1',
        '::ffff:8.8.8.8',
        '100.64.0',
        '100.64.0.256',
        'fd7a:115c:a1e0::1::2',
        'fd7a:115c:a1e0:1:2:3:4:5:6',
        'fd7a:115c:a1e0:+1::',
        'fd7a:115c:a1e0:12345::',
        'fd7a:115c:a1e0:1:2:3:4',
        '::ffff:1.2.3',
        'nas.tail123.ts.net',
        '',
      ]) {
        expect(
          TailnetHosts.isTailscaleAddress(address),
          isFalse,
          reason: address,
        );
      }
    });
  });
}
