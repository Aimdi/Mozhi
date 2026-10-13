import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mlkit_translator/src/mlkit_bindings.dart';
import 'package:mlkit_translator/src/mlkit_language_codes.dart';
import 'package:translation_repository/translation_repository.dart';

/// A model download or deletion reported failure.
final class MlKitModelException implements Exception {
  const new(this.operation, this.language);

  /// `download` or `delete`.
  final String operation;

  /// ML Kit code of the model.
  final String language;

  @override
  String toString() => 'MlKitModelException($operation $language failed)';
}

/// [OfflineTranslator] backed by Google ML Kit on-device translation
/// (Android and iOS; ~30 MB per language model).
///
/// Accepts any app/catalogue code and maps it onto ML Kit's 59 models (see
/// [MlKitLanguageCodes.toMlKit]: `zh-TW` -> `zh`, `pt-BR` -> `pt`,
/// `nb` -> `no`, `iw` -> `he`, `fil` -> `tl`, ...).
///
/// [translate] never downloads anything: it checks both models first and
/// throws [OfflineModelMissingException] (ML Kit's own `translateText`
/// would silently download missing models over any network on Android).
/// Native translators are cached per language pair (the
/// [maxCachedTranslators] most recently used ones) and released by
/// [dispose].
///
/// On other platforms [isAvailable] is false, [downloadedLanguages] is empty,
/// [identifyLanguage] returns null and the other operations throw
/// [UnsupportedError].
class MlKitOfflineTranslator implements OfflineTranslator {
  new({
    this._bindings,
    this._isAvailable,
    this.maxCachedTranslators = 3,
    this.confidenceThreshold = 0.5,
  }) : assert(maxCachedTranslators > 0, 'Cache at least one translator');

  /// Whether ML Kit runs on the current platform (Android or iOS, not web).
  static bool get isPlatformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// How many native translators (language pairs) stay open.
  final int maxCachedTranslators;

  /// Minimum confidence (0..1) for [identifyLanguage].
  final double confidenceThreshold;

  MlKitBindings? _bindings;
  final bool? _isAvailable;
  final Map<String, _CachedTranslator> _translators = {};
  MlKitLanguageIdentifier? _identifier;

  /// Created lazily so constructing this class never touches plugins.
  MlKitBindings get _plugin => _bindings ??= GoogleMlKitBindings();

  @override
  bool get isAvailable => _isAvailable ?? isPlatformSupported;

  @override
  Set<String> get supportedLanguages => MlKitLanguageCodes.supported;

  /// Number of open native translators (for diagnostics and tests).
  @visibleForTesting
  int get cachedTranslatorCount => _translators.length;

  @override
  Future<Set<String>> downloadedLanguages() async {
    if (!isAvailable) return const {};
    final codes = supportedLanguages.toList();
    final downloaded = await Future.wait(codes.map(_plugin.isModelDownloaded));
    return {
      for (var i = 0; i < codes.length; i++)
        if (downloaded[i]) codes[i],
    };
  }

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {
    _ensureAvailable();
    final model = _require(code);
    final ok = await _plugin.downloadModel(model, wifiRequired: wifiOnly);
    if (!ok) throw MlKitModelException('download', model);
  }

  @override
  Future<void> deleteLanguage(String code) async {
    _ensureAvailable();
    final model = _require(code);
    // Release translators that hold the model before it disappears.
    final keys = [
      for (final MapEntry(:key, :value) in _translators.entries)
        if (value.source == model || value.target == model) key,
    ];
    await Future.wait([
      for (final key in keys) _translators.remove(key)!.evict(),
    ]);
    final ok = await _plugin.deleteModel(model);
    if (!ok) throw MlKitModelException('delete', model);
  }

  /// Translates [text] from [source] to [target].
  ///
  /// [source] may be `auto` (or empty): the language is then identified
  /// first. Blank text and identical (mapped) languages return [text]
  /// unchanged. Throws [OfflineLanguageUnsupportedException] for languages
  /// without an ML Kit model and [OfflineModelMissingException] (listing ML
  /// Kit codes) when a model is not downloaded.
  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    _ensureAvailable();
    final to = _require(target);
    if (text.trim().isEmpty) return text;
    final from = _isAuto(source)
        ? await _identifySource(text)
        : _require(source);
    if (from == to) return text;

    final pair = {from, to}.toList();
    final present = await Future.wait(pair.map(_plugin.isModelDownloaded));
    final missing = [
      for (var i = 0; i < pair.length; i++)
        if (!present[i]) pair[i],
    ];
    if (missing.isNotEmpty) throw OfflineModelMissingException(missing);

    return await _translatorFor(from, to).translate(text);
  }

  /// BCP-47 code of [text]'s language (see
  /// [MlKitLanguageCodes.normalizeIdentified]), or null when undetermined,
  /// blank or unavailable on this platform. The result may be a language
  /// without a translation model (e.g. `yo`).
  @override
  Future<String?> identifyLanguage(String text) async {
    if (!isAvailable || text.trim().isEmpty) return null;
    final identifier = _identifier ??= _plugin.createLanguageIdentifier(
      confidenceThreshold: confidenceThreshold,
    );
    return MlKitLanguageCodes.normalizeIdentified(
      await identifier.identify(text),
    );
  }

  /// Closes all native translators and the language identifier. The
  /// instance stays usable; later calls create new native objects.
  @override
  Future<void> dispose() async {
    final translators = _translators.values.toList();
    _translators.clear();
    final identifier = _identifier;
    _identifier = null;
    await Future.wait([
      for (final translator in translators) translator.evict(),
      if (identifier != null) _closeQuietly(identifier.close),
    ]);
  }

  void _ensureAvailable() {
    if (!isAvailable) {
      throw UnsupportedError(
        'Offline translation is available on Android and iOS only',
      );
    }
  }

  static bool _isAuto(String code) {
    final key = code.trim().toLowerCase();
    return key.isEmpty || key == 'auto';
  }

  static String _require(String code) =>
      MlKitLanguageCodes.toMlKit(code) ??
      (throw OfflineLanguageUnsupportedException(code));

  Future<String> _identifySource(String text) async {
    final identified = await identifyLanguage(text);
    final model = identified == null
        ? null
        : MlKitLanguageCodes.toMlKit(identified);
    return model ??
        (throw OfflineLanguageUnsupportedException(identified ?? 'auto'));
  }

  _CachedTranslator _translatorFor(String from, String to) {
    final key = '$from>$to';
    final cached = _translators.remove(key);
    if (cached != null) return _translators[key] = cached;
    final created = _CachedTranslator(
      from,
      to,
      _plugin.createTranslator(source: from, target: to),
    );
    _translators[key] = created;
    while (_translators.length > maxCachedTranslators) {
      unawaited(_translators.remove(_translators.keys.first)!.evict());
    }
    return created;
  }
}

/// A native translator that is closed once evicted and idle, so evicting it
/// never breaks a translation that is still running.
class _CachedTranslator {
  new(this.source, this.target, this._translator);

  final String source;
  final String target;
  final MlKitTextTranslator _translator;
  int _running = 0;
  bool _evicted = false;
  Future<void>? _closing;

  Future<String> translate(String text) async {
    _running++;
    try {
      return await _translator.translate(text);
    } finally {
      _running--;
      if (_evicted && _running == 0) unawaited(_close());
    }
  }

  /// Closes now when idle, otherwise after the running translations.
  Future<void> evict() {
    _evicted = true;
    return _running == 0 ? _close() : Future<void>.value();
  }

  Future<void> _close() => _closing ??= _closeQuietly(_translator.close);
}

/// Releasing native resources must never surface as an error.
Future<void> _closeQuietly(Future<void> Function() close) async {
  try {
    await close();
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'mlkit_translator',
        context: ErrorDescription('while closing an ML Kit resource'),
      ),
    );
  }
}
