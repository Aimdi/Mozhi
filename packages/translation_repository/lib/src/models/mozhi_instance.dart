import 'package:meta/meta.dart';

/// A Mozhi instance the user can translate through.
@immutable
class MozhiInstance {
  const new({required this.url, this.label, this.isCustom = true});

  factory fromJson(Map<String, dynamic> json) => MozhiInstance(
    url: json['url'] as String,
    label: json['label'] as String?,
    isCustom: json['isCustom'] as bool? ?? true,
  );

  /// Normalised base URL (see `MozhiApiClient.normalizeBaseUrl`).
  final String url;
  final String? label;

  /// False for entries that came from the bundled public instance list.
  final bool isCustom;

  String get displayName =>
      (label?.isNotEmpty ?? false) ? label! : Uri.parse(url).host;

  Map<String, dynamic> toJson() => {
    'url': url,
    if (label != null) 'label': label,
    'isCustom': isCustom,
  };

  /// Public instances from Mozhi's `instances.json` (clearnet, no
  /// Cloudflare), as of Oct 2026.
  static const publicInstances = <MozhiInstance>[
    MozhiInstance(
      url: 'https://mozhi.aryak.me',
      label: 'mozhi.aryak.me (India)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://translate.projectsegfau.lt',
      label: 'projectsegfau.lt (DE/US/IN)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://translate.nerdvpn.de',
      label: 'nerdvpn.de (Ukraine)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.ducks.party',
      label: 'ducks.party (Germany)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.pussthecat.org',
      label: 'pussthecat.org (Germany)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.adminforge.de',
      label: 'adminforge.de (Germany)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://translate.privacyredirect.com',
      label: 'privacyredirect.com (Finland)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.canine.tools',
      label: 'canine.tools (USA)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mzh.dc09.xyz',
      label: 'dc09.xyz (Russia)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.bloat.cat',
      label: 'bloat.cat (Germany)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.catsarch.com',
      label: 'catsarch.com (USA)',
      isCustom: false,
    ),
  ];

  @override
  bool operator ==(Object other) => other is MozhiInstance && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
