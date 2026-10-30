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
  /// Cloudflare), the ones that translate with the app's default engine
  /// (Google) first, fastest first, as measured by
  /// `tool/check_public_instances.py` on 2026-10-30. Requests start at the
  /// first one, so a new install starts on a server that translates.
  static const publicInstances = <MozhiInstance>[
    MozhiInstance(
      url: 'https://mozhi.adminforge.de',
      label: 'adminforge.de (Germany)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.ducks.party',
      label: 'ducks.party (Germany)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mozhi.catsarch.com',
      label: 'catsarch.com (USA)',
      isCustom: false,
    ),
    MozhiInstance(
      url: 'https://mzh.dc09.xyz',
      label: 'dc09.xyz (Russia)',
      isCustom: false,
    ),
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
      url: 'https://mozhi.pussthecat.org',
      label: 'pussthecat.org (Germany)',
      isCustom: false,
    ),
  ];

  /// Servers an earlier version of the app listed by default and no longer
  /// does: unreachable (`translate.nerdvpn.de` no longer resolves,
  /// `translate.privacyredirect.com` refuses the API with HTTP 403) or
  /// behind a bot wall that answers an app with an HTML page instead of
  /// Mozhi's JSON (`mozhi.canine.tools`, `mozhi.bloat.cat`).
  /// [migrateDefaults] removes them from stored lists.
  static const retiredUrls = <String>{
    'https://translate.nerdvpn.de',
    'https://translate.privacyredirect.com',
    'https://mozhi.canine.tools',
    'https://mozhi.bloat.cat',
  };

  /// The URLs of every earlier default list, each in its order, oldest
  /// first. A stored list still in one of these orders was never arranged
  /// by the user (see [migrateDefaults]). Add the current list here
  /// whenever it changes.
  static const previousDefaultOrders = <List<String>>[
    // Versions up to October 2026.
    [
      'https://mozhi.aryak.me',
      'https://translate.projectsegfau.lt',
      'https://translate.nerdvpn.de',
      'https://mozhi.ducks.party',
      'https://mozhi.pussthecat.org',
      'https://mozhi.adminforge.de',
      'https://translate.privacyredirect.com',
      'https://mozhi.canine.tools',
      'https://mzh.dc09.xyz',
      'https://mozhi.bloat.cat',
      'https://mozhi.catsarch.com',
    ],
  ];

  /// A stored instance list (oldest settings included) brought up to date
  /// with the built-in list:
  ///
  /// * Built-in entries ([isCustom] false) of [retiredUrls] are dropped.
  /// * When the built-in entries that remain are, in order, exactly one of
  ///   the [previousDefaultOrders] (without the retired servers), the user
  ///   never arranged them: they are replaced by the current default list
  ///   ([publicInstances]), in its order. Custom instances before or after
  ///   them stay where they are.
  /// * Anything else is kept as it is: custom instances (also one whose
  ///   address is retired), a list the user reordered, or one from which
  ///   they removed or added servers.
  ///
  /// Pure and idempotent: a list that is already current comes back
  /// unchanged (an empty one too).
  static List<MozhiInstance> migrateDefaults(List<MozhiInstance> stored) {
    final kept = [
      for (final instance in stored)
        if (instance.isCustom || !retiredUrls.contains(instance.url)) instance,
    ];
    final first = kept.indexWhere((instance) => !instance.isCustom);
    if (first < 0) return List.unmodifiable(kept);
    final end = kept.lastIndexWhere((instance) => !instance.isCustom) + 1;
    final builtIn = kept.sublist(first, end);
    if (builtIn.any((instance) => instance.isCustom) ||
        !_isPreviousDefault([for (final instance in builtIn) instance.url])) {
      return List.unmodifiable(kept);
    }
    return List.unmodifiable(<MozhiInstance>{
      ...kept.sublist(0, first),
      ...publicInstances,
      ...kept.sublist(end),
    });
  }

  /// Whether [urls] is one of the [previousDefaultOrders] without its
  /// [retiredUrls].
  static bool _isPreviousDefault(List<String> urls) {
    for (final order in previousDefaultOrders) {
      final current = [
        for (final url in order)
          if (!retiredUrls.contains(url)) url,
      ];
      if (_sameOrder(current, urls)) return true;
    }
    return false;
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) => other is MozhiInstance && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
