import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart'
    show SessionHttpClient;
import 'package:mozhi/settings/models/model_source.dart';
import 'package:mozhi/settings/models/web_base_url.dart';

/// A kind of download a model mirror can host: its folder in the mirror
/// (the layout of `tool/mirror_models.py`).
enum MirrorDataKind {
  /// The offline languages (Firefox Translations models).
  translation('bergamot', originalHostAllowsBrowsers: false),

  /// The text recognition (Tesseract) language data.
  textRecognition('tesseract', originalHostAllowsBrowsers: true),

  /// The offline dictionaries (a GitHub release).
  dictionary('dictionary', originalHostAllowsBrowsers: false),

  /// The starter phrasebooks (a GitHub release).
  phrasebook('phrasebooks', originalHostAllowsBrowsers: false);

  new(this.folder, {required this.originalHostAllowsBrowsers});

  /// The kind's folder in the mirror, e.g. `bergamot`.
  final String folder;

  /// Whether the original publisher lets a web page download the files
  /// (it sends CORS headers): Tesseract's data on GitHub does; Mozilla's
  /// bucket (only for `localhost`) and GitHub release downloads do not.
  final bool originalHostAllowsBrowsers;
}

/// What a mirror's `<folder>/index.json` says about a kind of download.
enum MirrorHosting {
  /// The index lists files of the kind.
  hosted,

  /// No index (an error such as 404, or a page that is not one, e.g. a
  /// server answering unknown paths with the app's `index.html`), or an
  /// index without files.
  notHosted,

  /// The server could not be asked (no connection, a server error, a
  /// time-out): assumed to host it.
  unknown,
}

/// Asks, once per mirror and kind, whether the web server the web app
/// comes from hosts a kind of download, so that the offline languages,
/// dictionaries and text recognition screens can say so instead of
/// letting every download fail.
///
/// `tool/mirror_models.py` writes `<folder>/index.json` into every folder
/// of a mirror it fills (`{"schemaVersion": 1, "kind": "phrasebook",
/// "items": ["ar", ...]}`); the release's web zip carries
/// `models/phrasebooks/` with its index. Only the web app with
/// [ModelSourceKind.thisServer] is checked: Android and other mirrors
/// download as before.
class MirrorHostingProbe {
  new({
    this._client,
    this.isWeb = kIsWeb,
    Uri? Function()? appBase,
    this.timeout = const Duration(seconds: 10),
  }) : _appBase = appBase ?? webAppBaseUrl;

  /// The probe of the app's screens (replaceable in tests).
  static MirrorHostingProbe instance = MirrorHostingProbe();

  /// The name of a folder's index.
  static const indexFile = 'index.json';

  /// Whether the app runs in a browser.
  final bool isWeb;

  /// Maximum wait for an index.
  final Duration timeout;

  final http.Client? _client;
  final Uri? Function() _appBase;
  final Map<Uri, Future<MirrorHosting>> _answers = {};

  /// Whether downloads of [kind] from [source] are known not to work: in
  /// a browser, from this web server ([ModelSourceKind.thisServer]) when
  /// it does not host them ([MirrorHosting.notHosted]), unless [source]
  /// falls back to an original publisher that browsers can download from.
  Future<bool> downloadsBlocked(MirrorDataKind kind, ModelSource source) async {
    if (!isWeb || source.kind != ModelSourceKind.thisServer) return false;
    if (source.fallsBackToDefault && kind.originalHostAllowsBrowsers) {
      return false;
    }
    final mirror = source.mirror(appBase: _appBase());
    if (mirror == null) return false;
    return await hosting(mirror, kind) == MirrorHosting.notHosted;
  }

  /// What [mirror]'s index of [kind] says; asked once (again after an
  /// [MirrorHosting.unknown] answer).
  Future<MirrorHosting> hosting(Uri mirror, MirrorDataKind kind) {
    final url = mirror.resolve('${kind.folder}/$indexFile');
    if (_answers[url] case final answer?) return answer;
    final answer = _ask(url);
    _answers[url] = answer;
    unawaited(
      answer.then((hosting) {
        if (hosting == MirrorHosting.unknown) unawaited(_answers.remove(url));
      }),
    );
    return answer;
  }

  Future<MirrorHosting> _ask(Uri url) async {
    try {
      final response = await (_client ?? SessionHttpClient())
          .get(url)
          .timeout(timeout);
      final status = response.statusCode;
      if (status >= 500 || status == 408 || status == 429) {
        return MirrorHosting.unknown;
      }
      if (status != 200) return MirrorHosting.notHosted;
      return listsFiles(utf8.decode(response.bodyBytes, allowMalformed: true))
          ? MirrorHosting.hosted
          : MirrorHosting.notHosted;
    } on Object {
      return MirrorHosting.unknown;
    }
  }

  /// Whether [body] is a mirror folder's index that lists files: a JSON
  /// object with a non-empty `items` list.
  @visibleForTesting
  static bool listsFiles(String body) {
    try {
      return switch (jsonDecode(body)) {
        {'items': final List<Object?> items} => items.isNotEmpty,
        _ => false,
      };
    } on FormatException {
      return false;
    }
  }
}
