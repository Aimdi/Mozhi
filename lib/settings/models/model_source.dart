import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/settings/models/web_base_url.dart';

/// Where the on-device models (offline languages, voice input, text
/// recognition) are downloaded from (see [ModelSource]).
enum ModelSourceKind {
  /// The original publishers, each file's catalogue URL: Mozilla's
  /// Firefox Translations bucket on Google Cloud Storage, Tesseract's
  /// language data on GitHub and the Whisper models on Hugging Face.
  defaultHosts,

  /// The web server the web app was loaded from, at `models/` next to the
  /// app (a self-hoster's mirror, see `docs/self-hosting-mozhi.md`). Only
  /// in a browser.
  thisServer,

  /// A mirror at [ModelSource.customUrl]: the user's own server, a NAS on
  /// the local network, a `.onion` address.
  custom,
}

/// Why a mirror URL the user typed is not accepted
/// ([ModelSource.mirrorUrlProblem]).
enum ModelMirrorUrlProblem {
  /// Not an `http(s)` address with a host.
  invalid,

  /// It has a user name or password (not stored; mirrors are public).
  credentials,

  /// It has a query (`?`) or fragment (`#`).
  query,

  /// Plain `http` to a public server: only allowed for this device, the
  /// local network and `.onion` / `.i2p` addresses ([isCleartextAllowed]).
  cleartext,
}

/// The "Model source" setting (`AppSettings.modelSource`): where model
/// files come from. A mirror is not trusted: every file stays pinned by
/// size and SHA-256 in the app's catalogues and is checked the same way
/// whichever server sends it. It only changes who sees the IP address and
/// which languages are downloaded.
///
/// The packages resolve the URLs (`bergamotDownloadUrls`,
/// `whisperDownloadUrls`, `tessdataDownloadUrls`): with a [mirror],
/// `<mirror>/bergamot/…`, `<mirror>/whisper/…` and `<mirror>/tesseract/…`
/// (the layout `tool/mirror_models.py` writes), then the catalogue URL
/// only when [fallbackToDefault].
@immutable
class ModelSource extends Equatable {
  const new({
    this.kind = ModelSourceKind.defaultHosts,
    this.customUrl,
    this.fallbackToDefault = false,
  });

  /// Tolerant counterpart of [toJson]: an unknown kind, a
  /// [ModelSourceKind.custom] source without a valid URL and
  /// [ModelSourceKind.thisServer] outside a browser fall back to
  /// [platformDefault]. Never throws.
  factory fromJson(Map<String, dynamic> json) {
    final kind = ModelSourceKind.values.asNameMap()[json['kind']];
    final url = switch (json['url']) {
      final String url => normalizeMirrorUrl(url)?.toString(),
      _ => null,
    };
    final fallback = json['fallback'] == true;
    return switch (kind) {
      ModelSourceKind.custom when url == null => platformDefault,
      ModelSourceKind.thisServer when !kIsWeb => platformDefault,
      null => platformDefault,
      final kind => ModelSource(
        kind: kind,
        customUrl: url,
        fallbackToDefault: fallback,
      ),
    };
  }

  /// The original publishers ([ModelSourceKind.defaultHosts]).
  static const defaultHosts = ModelSource();

  /// A new install's source: the original publishers on Android; in a
  /// browser, the web server the app comes from
  /// ([ModelSourceKind.thisServer]), without falling back to the original
  /// publishers until the user allows it.
  static const platformDefault = ModelSource(
    kind: kIsWeb ? ModelSourceKind.thisServer : ModelSourceKind.defaultHosts,
  );

  /// The source of this run of the app, for the downloads that start
  /// outside the widget tree: `SettingsCubit` keeps it equal to
  /// `AppSettings.modelSource`.
  static ModelSource current = platformDefault;

  final ModelSourceKind kind;

  /// The mirror's base URL (normalised by [normalizeMirrorUrl]) for
  /// [ModelSourceKind.custom]. Kept when another kind is chosen, so that
  /// the dialog offers it again.
  final String? customUrl;

  /// Whether a file the mirror does not serve (an HTTP error, no
  /// connection) is downloaded from its original publisher instead. A
  /// file that does not match its checksum is never retried elsewhere.
  final bool fallbackToDefault;

  /// The mirror's base URL for the downloads, or null for the original
  /// publishers: `models/` next to the web app ([appBase], default its
  /// `document.baseURI`) for [ModelSourceKind.thisServer] (null outside a
  /// browser), [customUrl] for [ModelSourceKind.custom].
  Uri? mirror({Uri? appBase}) => switch (kind) {
    ModelSourceKind.defaultHosts => null,
    ModelSourceKind.thisServer => switch (appBase ?? webAppBaseUrl()) {
      final base? when base.isScheme('https') || base.isScheme('http') =>
        // A relative reference drops the page's query and fragment.
        base.resolve('models/'),
      _ => null,
    },
    ModelSourceKind.custom => switch (customUrl) {
      final url? => normalizeMirrorUrl(url),
      null => null,
    },
  };

  /// Whether downloads go to a mirror first.
  bool get usesMirror => kind != ModelSourceKind.defaultHosts;

  /// [fallbackToDefault], for a source that [usesMirror].
  bool get fallsBackToDefault => usesMirror && fallbackToDefault;

  /// [text] as a mirror base URL: trimmed, `https://` added when it has no
  /// scheme, with a trailing `/`; null when it is not a valid one (see
  /// [mirrorUrlProblem]).
  static Uri? normalizeMirrorUrl(String text) {
    if (mirrorUrlProblem(text) != null) return null;
    final uri = _parse(text)!;
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  /// Why [text] is not a valid mirror base URL, or null when it is one.
  static ModelMirrorUrlProblem? mirrorUrlProblem(String text) {
    final uri = _parse(text);
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty) {
      return ModelMirrorUrlProblem.invalid;
    }
    if (uri.userInfo.isNotEmpty) return ModelMirrorUrlProblem.credentials;
    if (uri.hasQuery || uri.hasFragment) return ModelMirrorUrlProblem.query;
    if (!isCleartextAllowed(uri)) return ModelMirrorUrlProblem.cleartext;
    return null;
  }

  static Uri? _parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
    return Uri.tryParse(trimmed.contains('://') ? trimmed : 'https://$trimmed');
  }

  /// Returns a copy with the given fields replaced.
  ModelSource copyWith({
    ModelSourceKind? kind,
    String? customUrl,
    bool? fallbackToDefault,
  }) => ModelSource(
    kind: kind ?? this.kind,
    customUrl: customUrl ?? this.customUrl,
    fallbackToDefault: fallbackToDefault ?? this.fallbackToDefault,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'url': ?customUrl,
    'fallback': fallbackToDefault,
  };

  @override
  List<Object?> get props => [kind, customUrl, fallbackToDefault];
}
