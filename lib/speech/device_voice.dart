import 'package:equatable/equatable.dart';

/// A voice of the device speech engine, as listed by `flutter_tts`
/// `getVoices` (Android, iOS, macOS, Windows and the web).
class DeviceVoice extends Equatable {
  const new({
    required this.name,
    required this.locale,
    this.identifier,
    this.quality,
    this.networkRequired = false,
  });

  /// Android feature of voices whose data is not downloaded yet.
  static const notInstalledFeature = 'notInstalled';

  /// Engine quality labels that mean "better than the default voice"
  /// (Android `very high` / `high`, Apple `enhanced` / `premium`).
  static const highQualityLabels = {'very high', 'high', 'enhanced', 'premium'};

  /// Parses one entry of `flutter_tts` `getVoices`. Null when it has no
  /// name or locale, or when Android reports the voice as not installed
  /// (selecting it would fail or start a download).
  static DeviceVoice? fromEngine(Object? value) {
    if (value is! Map) return null;
    final name = _text(value['name']);
    final locale = _text(value['locale']);
    if (name == null || locale == null) return null;
    final features = '${value['features'] ?? ''}'.split('\t');
    if (features.contains(notInstalledFeature)) return null;
    return DeviceVoice(
      name: name,
      locale: locale,
      identifier: _text(value['identifier']),
      quality: _text(value['quality']),
      networkRequired: '${value['network_required']}' == '1',
    );
  }

  /// Tolerant counterpart of [toJson]: null when [json] is not a voice.
  static DeviceVoice? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = _text(json['name']);
    final locale = _text(json['locale']);
    if (name == null || locale == null) return null;
    return DeviceVoice(
      name: name,
      locale: locale,
      identifier: _text(json['identifier']),
      quality: _text(json['quality']),
      networkRequired: json['networkRequired'] == true,
    );
  }

  /// The engine's name of the voice (e.g. `Amélie`, `fr-fr-x-frd-local`).
  final String name;

  /// The voice's language tag as the engine reports it (`fr-FR`; some
  /// engines use `fr_FR`).
  final String locale;

  /// Apple voice identifier; `setVoice` prefers it on iOS and macOS.
  final String? identifier;

  /// The engine's quality label, if any (see [highQualityLabels]).
  final String? quality;

  /// The voice is synthesised online, so the text it reads leaves the
  /// device: Android voices that need a network connection, and browser
  /// voices that are not a `localService` (Chrome's "Google …" voices).
  final bool networkRequired;

  /// Who receives the text of an online voice ([networkRequired]), when
  /// its name tells: `Google` for Chrome's "Google …" voices and the
  /// `…-network` voices of Google's Android engine, `Microsoft` for Edge's
  /// "Microsoft … Online" voices. Null for other voices.
  String? get onlineProvider {
    if (!networkRequired) return null;
    final lower = name.toLowerCase();
    if (lower.contains('google') ||
        (_engineIdPattern.hasMatch(name) && lower.endsWith('-network'))) {
      return 'Google';
    }
    if (lower.contains('microsoft')) return 'Microsoft';
    return null;
  }

  /// A copy whose [networkRequired] is [online].
  DeviceVoice withNetworkRequired({required bool online}) =>
      online == networkRequired
      ? this
      : DeviceVoice(
          name: name,
          locale: locale,
          identifier: identifier,
          quality: quality,
          networkRequired: online,
        );

  /// Whether the engine rates this voice above its default quality.
  bool get isHighQuality =>
      highQualityLabels.contains(quality?.trim().toLowerCase());

  /// Identifies the voice across listings (name and locale; the quality
  /// labels may change with engine updates).
  String get id => '$normalizedLocale/$name';

  /// [locale] with `-` separators, lower case (for comparisons).
  String get normalizedLocale => _normalize(locale);

  /// Whether this voice speaks [languageTag] (same primary language, e.g.
  /// `fr-CA` speaks `fr`).
  bool speaks(String languageTag) =>
      normalizedLocale.split('-').first ==
      _normalize(languageTag).split('-').first;

  /// Whether [name] is a technical engine id rather than a name meant for
  /// people, e.g. Google's `fr-fr-x-frd-local` / `en-us-x-iob-network`,
  /// `fr-FR-language` or Samsung's `en-US-SMTf00`: the name starts with the
  /// voice's locale and has no spaces. Show such voices by number
  /// ([numberAmong]) instead.
  bool get hasEngineName {
    if (_engineIdPattern.hasMatch(name)) return true;
    final normalized = _normalize(name);
    return !normalized.contains(_whitespace) &&
        normalized.startsWith('$normalizedLocale-');
  }

  /// The part of an engine name ([hasEngineName]) that tells voices of the
  /// same locale apart, e.g. `frd` for `fr-fr-x-frd-local`, `smtf00` for
  /// `en-US-SMTf00`; null for names meant for people.
  String? get engineVariant {
    if (!hasEngineName) return null;
    final normalized = _normalize(name);
    if (_engineIdPattern.firstMatch(normalized) case final match?) {
      return match.group(2);
    }
    return normalized.substring(normalizedLocale.length + 1);
  }

  /// The 1-based position of this voice among the voices of [voices] with
  /// an engine name ([hasEngineName]) and the same locale, ordered by name,
  /// e.g. 3 for `fr-fr-x-frd-network` next to `fr-fr-x-frb-local` and
  /// `fr-fr-x-frd-local`. Null when this voice has a name meant for people
  /// or is not in [voices].
  int? numberAmong(Iterable<DeviceVoice> voices) {
    if (!hasEngineName) return null;
    final names = {
      for (final voice in voices)
        if (voice.hasEngineName && voice.normalizedLocale == normalizedLocale)
          voice.name.toLowerCase(),
    }.toList()..sort();
    final index = names.indexOf(name.toLowerCase());
    return index < 0 ? null : index + 1;
  }

  /// Arguments of `flutter_tts` `setVoice`.
  Map<String, String> toEngine() => {
    'name': name,
    'locale': locale,
    'identifier': ?identifier,
  };

  Map<String, dynamic> toJson() => {
    'name': name,
    'locale': locale,
    'identifier': ?identifier,
    'quality': ?quality,
    if (networkRequired) 'networkRequired': true,
  };

  /// Orders [voices] for [languageTag]: voices whose locale matches the tag
  /// exactly first, then by locale and name (case-insensitive). Drops
  /// duplicates (same name and locale).
  static List<DeviceVoice> sortFor(
    String languageTag,
    Iterable<DeviceVoice> voices,
  ) {
    final wanted = _normalize(languageTag);
    final seen = <(String, String)>{};
    final unique = [
      for (final voice in voices)
        if (seen.add((voice.name, voice.normalizedLocale))) voice,
    ];
    int rank(DeviceVoice voice) => voice.normalizedLocale == wanted ? 0 : 1;
    return unique..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final byLocale = a.normalizedLocale.compareTo(b.normalizedLocale);
      if (byLocale != 0) return byLocale;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  @override
  List<Object?> get props => [
    name,
    locale,
    identifier,
    quality,
    networkRequired,
  ];
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _normalize(String tag) => tag.trim().replaceAll('_', '-').toLowerCase();

/// Android engine voice ids, `language[-region]-x-variant-(local|network)`
/// (group 2 is the variant).
final _engineIdPattern = RegExp(
  r'^[a-z]{2,3}(-[a-z0-9]{2,4})?-x-([a-z0-9]+)-(?:local|network)$',
  caseSensitive: false,
);

final _whitespace = RegExp(r'\s');
