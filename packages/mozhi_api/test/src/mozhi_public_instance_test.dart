import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

void main() {
  group('MozhiPublicInstance', () {
    test('parses the upstream format', () {
      final instance = MozhiPublicInstance.fromJson(const {
        'link': 'https://mozhi.example',
        'country': 'Germany',
        'host': 'Hetzner',
        'cloudflare': true,
        'onion': 'http://abc.onion',
        'i2p': 'http://abc.b32.i2p',
      });

      expect(
        instance,
        const MozhiPublicInstance(
          url: 'https://mozhi.example',
          country: 'Germany',
          // Known country names get their region codes.
          regions: ['DE'],
          isp: 'Hetzner',
          cloudflare: true,
          onion: 'http://abc.onion',
          i2p: 'http://abc.b32.i2p',
        ),
      );
      expect(instance.addresses, [
        'https://mozhi.example',
        'http://abc.onion',
        'http://abc.b32.i2p',
      ]);
      expect(MozhiPublicInstance.fromJson(instance.toJson()), instance);
    });

    test('accepts alternative keys and ignores blanks and odd types', () {
      final instance = MozhiPublicInstance.fromJson(const {
        'url': ' https://mozhi.example ',
        'isp': 'OVH',
        'tor': 'http://abc.onion',
        'country': '  ',
        'cloudflare': 'yes',
        'i2p': 42,
      });

      expect(instance.url, 'https://mozhi.example');
      expect(instance.isp, 'OVH');
      expect(instance.onion, 'http://abc.onion');
      expect(instance.country, isNull);
      expect(instance.cloudflare, isFalse);
      expect(instance.i2p, isNull);
      expect(instance.toJson(), {
        'link': 'https://mozhi.example',
        'host': 'OVH',
        'cloudflare': false,
        'onion': 'http://abc.onion',
      });
    });

    test('reads region codes, else derives them from the country', () {
      expect(
        MozhiPublicInstance.fromJson(const {
          'link': 'https://a.example',
          'country': 'Somewhere',
          'regions': ['fr', ' ', 7],
        }).regions,
        ['FR'],
      );
      expect(
        MozhiPublicInstance.fromJson(const {
          'link': 'https://a.example',
          'country': 'Germany, USA, India',
        }).regions,
        ['DE', 'US', 'IN'],
      );
      // Not every name is known: no codes rather than some.
      expect(
        MozhiPublicInstance.fromJson(const {
          'link': 'https://a.example',
          'country': 'Germany, Atlantis',
        }).regions,
        isEmpty,
      );
      expect(MozhiPublicInstance.regionCodesOf(null), isEmpty);
      expect(MozhiPublicInstance.regionCodesOf(' , '), isEmpty);
      const instance = MozhiPublicInstance(
        url: 'https://a.example',
        country: 'Russia',
        regions: ['RU'],
      );
      expect(instance.toJson()['regions'], ['RU']);
      expect(MozhiPublicInstance.fromJson(instance.toJson()), instance);
      expect(
        instance,
        isNot(
          const MozhiPublicInstance(
            url: 'https://a.example',
            country: 'Russia',
          ),
        ),
      );
      expect(
        instance,
        isNot(
          const MozhiPublicInstance(
            url: 'https://a.example',
            country: 'Russia',
            regions: ['RS'],
          ),
        ),
      );
    });

    test('equality, hash code and toString', () {
      const a = MozhiPublicInstance(url: 'https://a.example', country: 'X');
      const b = MozhiPublicInstance(url: 'https://a.example', country: 'X');
      const c = MozhiPublicInstance(
        url: 'https://a.example',
        country: 'X',
        cloudflare: true,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.toString(), 'MozhiPublicInstance(https://a.example)');
      expect(
        c.toString(),
        'MozhiPublicInstance(https://a.example, cloudflare)',
      );
    });

    group('snapshot', () {
      const all = MozhiPublicInstance.all;

      test('names its source and date', () {
        expect(MozhiPublicInstance.sourceUrl, endsWith('/instances.json'));
        expect(DateTime.tryParse(MozhiPublicInstance.snapshotDate), isNotNull);
      });

      test('every entry has an address; clearnet ones are https', () {
        for (final instance in all) {
          expect(instance.addresses, isNotEmpty, reason: '$instance');
          if (instance.url case final url?) {
            expect(Uri.parse(url).isScheme('https'), isTrue, reason: url);
          }
        }
      });

      test('addresses are canonical and unique', () {
        final addresses = [for (final i in all) ...i.addresses];
        expect(addresses.toSet(), hasLength(addresses.length));
        for (final address in addresses) {
          expect(MozhiApiClient.normalizeBaseUrl(address).toString(), address);
        }
      });

      test('clearnet servers with a country have its region codes', () {
        for (final instance in all) {
          if (instance.country case final country?) {
            expect(
              instance.regions,
              MozhiPublicInstance.regionCodesOf(country),
              reason: country,
            );
            expect(instance.regions, isNotEmpty, reason: country);
          }
        }
      });

      test('hidden service addresses use their own top-level domain', () {
        for (final instance in all) {
          if (instance.onion case final onion?) {
            expect(Uri.parse(onion).host, endsWith('.onion'));
          }
          if (instance.i2p case final i2p?) {
            expect(Uri.parse(i2p).host, endsWith('.i2p'));
          }
        }
      });
    });
  });
}
