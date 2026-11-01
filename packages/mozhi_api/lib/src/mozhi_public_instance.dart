import 'package:meta/meta.dart';

/// One entry of Mozhi's public instance list, `instances.json` in the Mozhi
/// repository ([sourceUrl]).
///
/// Upstream JSON (one object per operator):
///
/// ```json
/// {
///   "link": "https://mozhi.aryak.me",
///   "country": "India",
///   "regions": ["IN"],
///   "host": "Airtel",
///   "cloudflare": false,
///   "onion": "http://mozhi.….onion",
///   "i2p": "http://….b32.i2p"
/// }
/// ```
///
/// [all] is a snapshot bundled with the app; nothing is fetched at run
/// time.
@immutable
class MozhiPublicInstance {
  const new({
    this.url,
    this.country,
    this.regions = const [],
    this.isp,
    this.cloudflare = false,
    this.onion,
    this.i2p,
  });

  /// Parses an upstream entry. Accepts `link` or `url`, `host` or `isp`,
  /// and `onion` or `tor`; blank strings read as absent. [regions] come
  /// from `regions` (ISO codes), else from the [country] names the app
  /// knows ([regionCodesOf]).
  factory fromJson(Map<String, dynamic> json) => MozhiPublicInstance(
    url: _text(json['link']) ?? _text(json['url']),
    country: _text(json['country']),
    regions: switch (json['regions']) {
      final List<dynamic> codes => [
        for (final code in codes)
          if (_text(code) case final code?) code.toUpperCase(),
      ],
      _ => regionCodesOf(_text(json['country'])),
    },
    isp: _text(json['host']) ?? _text(json['isp']),
    cloudflare: json['cloudflare'] == true,
    onion: _text(json['onion']) ?? _text(json['tor']),
    i2p: _text(json['i2p']),
  );

  /// The clearnet `https://` URL, or null for an instance that is only
  /// known by its Tor or I2P address.
  final String? url;

  /// Where the server is, as upstream writes it, in English (`Germany`,
  /// `USA`, ...). Apps show [regions] in their UI language instead.
  final String? country;

  /// Where the server is: ISO 3166-1 alpha-2 region codes (`DE`, `US`),
  /// in the order of [country]; empty when unknown.
  final List<String> regions;

  /// Who hosts the server (upstream `host`), when known.
  final String? isp;

  /// Whether the clearnet [url] is fronted by Cloudflare, which terminates
  /// TLS and can therefore read every text sent to the instance.
  final bool cloudflare;

  /// Tor onion service address (`http://….onion`), if any.
  final String? onion;

  /// I2P address (`http://….i2p`), if any.
  final String? i2p;

  /// Every address of this instance: [url], [onion] and [i2p], in that
  /// order, without the absent ones.
  List<String> get addresses => [?url, ?onion, ?i2p];

  /// The upstream JSON shape (see the class documentation).
  Map<String, dynamic> toJson() => {
    'link': ?url,
    'country': ?country,
    if (regions.isNotEmpty) 'regions': regions,
    'host': ?isp,
    'cloudflare': cloudflare,
    'onion': ?onion,
    'i2p': ?i2p,
  };

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  /// The region codes of an upstream [country] text (`Germany, USA` ->
  /// `DE`, `US`); empty unless every name is one the app knows.
  static List<String> regionCodesOf(String? country) {
    if (country == null) return const [];
    final codes = [
      for (final name in country.split(','))
        if (name.trim().isNotEmpty) _regionCodes[name.trim().toLowerCase()],
    ];
    return codes.isEmpty || codes.contains(null)
        ? const []
        : List.unmodifiable(codes.whereType<String>());
  }

  /// Upstream country names (lower case) -> ISO region codes.
  static const _regionCodes = {
    'germany': 'DE',
    'usa': 'US',
    'us': 'US',
    'united states': 'US',
    'russia': 'RU',
    'india': 'IN',
  };

  /// Where [all] comes from.
  static const sourceUrl =
      'https://codeberg.org/aryak/mozhi/raw/branch/master/instances.json';

  /// When [all] was taken (ISO 8601 date).
  static const snapshotDate = '2026-10-30';

  /// The bundled snapshot of Mozhi's public instances.
  ///
  /// Derived from the upstream list as mirrored by LibRedirect's instance
  /// data (`link`, `onion` and `i2p` fields, Cloudflare detected by DNS:
  /// no Mozhi instance is behind it) and the countries of the app's default
  /// list. Hosting providers are not known for this snapshot. Tor and I2P
  /// addresses are attached to a clearnet URL only where the operator is
  /// evident from the address; the others are listed on their own.
  ///
  /// Clearnet servers come in the order of the app's default list (those
  /// that translate with Google first). Servers an app can't use are left
  /// out (checked on 2026-10-30): `translate.nerdvpn.de` (no longer
  /// resolves), `translate.privacyredirect.com` (refuses the API with HTTP
  /// 403), `mozhi.canine.tools` and `mozhi.bloat.cat` (a bot wall answers
  /// with an HTML page).
  static const all = <MozhiPublicInstance>[
    MozhiPublicInstance(
      url: 'https://mozhi.adminforge.de',
      country: 'Germany',
      regions: ['DE'],
    ),
    MozhiPublicInstance(
      url: 'https://mozhi.ducks.party',
      country: 'Germany',
      regions: ['DE'],
    ),
    MozhiPublicInstance(
      url: 'https://mozhi.catsarch.com',
      country: 'USA',
      regions: ['US'],
      onion:
          'http://mozhi.catsarchywsyuss6jdxlypsw5dc7owd5u5tr6bujxb7o6xw2hipqehyd'
          '.onion',
    ),
    MozhiPublicInstance(
      url: 'https://mzh.dc09.xyz',
      country: 'Russia',
      regions: ['RU'],
    ),
    MozhiPublicInstance(
      url: 'https://mozhi.aryak.me',
      country: 'India',
      regions: ['IN'],
      onion:
          'http://mozhi.wsuno6lnjdcsiok5mrxvl6e2bdex7nhsqqav6ux7tkwrqiqnulejfbyd'
          '.onion',
    ),
    MozhiPublicInstance(
      url: 'https://translate.projectsegfau.lt',
      country: 'Germany, USA, India',
      regions: ['DE', 'US', 'IN'],
    ),
    MozhiPublicInstance(
      url: 'https://mozhi.pussthecat.org',
      country: 'Germany',
      regions: ['DE'],
    ),
    MozhiPublicInstance(
      onion: 'http://42i2bzogwkph3dvoo2bm6srskf7vvabsphw7uzftymbjjlzgfluhnmid.onion',
    ),
    MozhiPublicInstance(
      onion: 'http://3mu2almmcv7rd7wlwhmkbwqgttntgpqu3hdanutxbv2v72wzbxe5ixqd.onion',
    ),
    MozhiPublicInstance(
      i2p:
          'http://74lptlnvaukcjnmqefedgna35ahkqexqzq2qq3k7utc2ep4jotcq.b32.i2p',
    ),
    MozhiPublicInstance(
      i2p:
          'http://b5jb6gilzl43u5js4d7jtcqmsk3xdjfbiowudij5yyhpm5bub3kq.b32.i2p',
    ),
  ];

  @override
  bool operator ==(Object other) =>
      other is MozhiPublicInstance &&
      other.url == url &&
      other.country == country &&
      _sameList(other.regions, regions) &&
      other.isp == isp &&
      other.cloudflare == cloudflare &&
      other.onion == onion &&
      other.i2p == i2p;

  @override
  int get hashCode => Object.hash(
    url,
    country,
    Object.hashAll(regions),
    isp,
    cloudflare,
    onion,
    i2p,
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'MozhiPublicInstance(${addresses.join(', ')}'
      '${cloudflare ? ', cloudflare' : ''})';
}
