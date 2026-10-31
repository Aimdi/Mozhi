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

    test('a record is fresh for ttl, and keeps its verdict after', () {
      const host = 'nas.tail123.ts.net';
      final at = DateTime.utc(2026, 10, 31, 12);
      expect(TailnetHosts.isFresh(host), isFalse);

      TailnetHosts.record(host, ['100.64.0.1'], at: at);
      expect(TailnetHosts.ttl, const Duration(seconds: 60));
      expect(TailnetHosts.isFresh(host, now: at), isTrue);
      expect(
        TailnetHosts.isFresh(host, now: at.add(const Duration(seconds: 59))),
        isTrue,
      );
      expect(
        TailnetHosts.isFresh(host, now: at.add(TailnetHosts.ttl)),
        isFalse,
      );
      // A clock that went back does not make it fresh forever.
      expect(
        TailnetHosts.isFresh(
          host,
          now: at.subtract(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(
        TailnetHosts.isFresh(
          host,
          now: at.add(const Duration(seconds: 5)),
          maxAge: const Duration(seconds: 5),
        ),
        isFalse,
      );
      // The app looks it up again; until then the verdict stands.
      expect(TailnetHosts.isPrivate(host), isTrue);
      // Now.
      TailnetHosts.record(host, ['100.64.0.1']);
      expect(TailnetHosts.isFresh(host), isTrue);
    });

    test('addressesOf gives the checked addresses of a private name', () {
      const host = 'nas.tail123.ts.net';
      expect(TailnetHosts.addressesOf(host), isEmpty);
      TailnetHosts.record(host, [' 100.64.0.1', 'fd7a:115c:a1e0::1']);
      expect(TailnetHosts.addressesOf('NAS.tail123.ts.net.'), [
        '100.64.0.1',
        'fd7a:115c:a1e0::1',
      ]);
      TailnetHosts.record(host, ['100.64.0.1', '203.0.113.5']);
      expect(TailnetHosts.addressesOf(host), isEmpty);
    });

    test('isTailscaleUla: only fd7a:115c:a1e0::/48', () {
      for (final address in [
        'fd7a:115c:a1e0::1',
        '[FD7A:115C:A1E0:AB12::1]',
        'fd7a:115c:a1e0::1%tun0',
      ]) {
        expect(TailnetHosts.isTailscaleUla(address), isTrue, reason: address);
      }
      for (final address in [
        '100.64.0.1',
        '::ffff:100.64.1.2',
        'fd7a:115c:a1e1::1',
        'fd00::1',
        'nas.tail123.ts.net',
        '',
      ]) {
        expect(TailnetHosts.isTailscaleUla(address), isFalse, reason: address);
      }
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
