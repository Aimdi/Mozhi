import 'dart:async';

import 'package:mt_api/mt_api.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/repository/deepl_glossaries.dart';
import 'package:translation_repository/src/repository/mappers.dart';

/// Creates a DeepL client for a [MtService.deepl] provider.
typedef DeeplClientBuilder = DeeplClient Function(AiProviderConfig config);

/// Creates a LibreTranslate client for a [MtService.libreTranslate]
/// provider.
typedef LibreClientBuilder = LibreTranslateClient Function(
  AiProviderConfig config,
);

/// Machine translation services configured as providers
/// (`AiProviderConfig.service` = [MtService.deepl] or
/// [MtService.libreTranslate]).
///
/// Owns one client per provider (replaced when its connection settings
/// change) and caches each provider's language lists in memory.
class MtEngines {
  new({DeeplClientBuilder? deepl, LibreClientBuilder? libre})
    : _deeplBuilder = deepl ?? defaultDeeplClient,
      _libreBuilder = libre ?? defaultLibreClient;

  /// `DeeplClient(authKey: apiKey, baseUrl: baseUrl or the official API)`.
  static DeeplClient defaultDeeplClient(AiProviderConfig config) {
    final base = config.baseUrl.trim();
    return DeeplClient(
      authKey: config.apiKey ?? '',
      baseUrl: base.isEmpty ? null : Uri.parse(_withScheme(base)),
    );
  }

  /// `LibreTranslateClient(baseUrl: normalised baseUrl, apiKey: apiKey)`.
  static LibreTranslateClient defaultLibreClient(AiProviderConfig config) =>
      LibreTranslateClient(
        baseUrl: LibreTranslateClient.normalizeBaseUrl(config.baseUrl),
        apiKey: config.apiKey,
      );

  final DeeplClientBuilder _deeplBuilder;
  final LibreClientBuilder _libreBuilder;
  final Map<String, ({String key, Object client})> _clients = {};

  /// The DeepL glossaries made from `TranslationOptions.glossary`.
  final DeeplGlossaries glossaries = DeeplGlossaries();

  /// Raw language lists keyed by connection key (+ direction).
  final Map<String, Future<List<DeeplLanguage>>> _deeplLanguages = {};
  final Map<String, Future<List<LibreLanguage>>> _libreLanguages = {};

  /// Separates the connection key from the rest of a language cache key.
  static const _separator = '\u0001';

  /// The connection settings of [config] (service, base URL, key).
  static String connectionKey(AiProviderConfig config) => [
    config.service.name,
    config.baseUrl.trim(),
    config.apiKey?.trim() ?? '',
  ].join('\u0000');

  T _client<T extends Object>(
    AiProviderConfig config,
    T Function(AiProviderConfig) build,
  ) {
    final key = connectionKey(config);
    final cached = _clients[config.id];
    if (cached != null && cached.key == key && cached.client is T) {
      return cached.client as T;
    }
    if (cached != null) _close(cached.client);
    final client = build(config);
    _clients[config.id] = (key: key, client: client);
    return client;
  }

  DeeplClient _deepl(AiProviderConfig config) => _client(config, _deeplBuilder);

  LibreTranslateClient _libre(AiProviderConfig config) =>
      _client(config, _libreBuilder);

  static void _close(Object client) {
    if (client is DeeplClient) client.close();
    if (client is LibreTranslateClient) client.close();
  }

  /// Closes clients (and drops language lists) of providers that were
  /// removed or whose connection settings changed.
  void update(List<AiProviderConfig> providers) {
    final keys = {
      for (final provider in providers)
        if (provider.isMtService) provider.id: connectionKey(provider),
    };
    _clients.removeWhere((id, entry) {
      if (keys[id] == entry.key) return false;
      _close(entry.client);
      return true;
    });
    final live = keys.values.toSet();
    bool stale(String cacheKey) =>
        !live.contains(cacheKey.substring(0, cacheKey.indexOf(_separator)));
    _deeplLanguages.removeWhere((key, _) => stale(key));
    _libreLanguages.removeWhere((key, _) => stale(key));
  }

  /// Forgets every cached language list.
  void clearLanguages() {
    _deeplLanguages.clear();
    _libreLanguages.clear();
  }

  /// Closes every client.
  void dispose() {
    for (final entry in _clients.values) {
      _close(entry.client);
    }
    _clients.clear();
    clearLanguages();
    glossaries.clear();
  }

  // Languages.

  Future<List<DeeplLanguage>> _deeplList(
    AiProviderConfig config,
    DeeplLanguageType type, {
    Object Function()? unlessCached,
  }) => _cached(
    _deeplLanguages,
    '${connectionKey(config)}$_separator${type.name}',
    () => _deepl(config).languages(type: type),
    unlessCached: unlessCached,
  );

  Future<List<LibreLanguage>> _libreList(
    AiProviderConfig config, {
    Object Function()? unlessCached,
  }) => _cached(
    _libreLanguages,
    '${connectionKey(config)}$_separator',
    () => _libre(config).languages(),
    unlessCached: unlessCached,
  );

  /// The cached future for [key], else [load]'s (cached until it fails).
  /// With [unlessCached], nothing is loaded: its result is thrown instead.
  static Future<T> _cached<T>(
    Map<String, Future<T>> cache,
    String key,
    Future<T> Function() load, {
    Object Function()? unlessCached,
  }) {
    final cached = cache[key];
    if (cached != null) return cached;
    if (unlessCached != null) return Future.error(unlessCached());
    final future = Future.sync(load);
    cache[key] = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          cache.removeWhere((_, value) => identical(value, future));
        },
      ),
    );
    return future;
  }

  /// Source languages: [Language.auto] (both services detect the language)
  /// followed by the service's languages, with app codes (`EN` -> `en`,
  /// `ZH` -> `zh-CN`, `pb` -> `pt-BR`, `nb` -> `no`).
  ///
  /// With [unlessCached], a list that is not in memory is not loaded: the
  /// error it returns is thrown instead (no request is made).
  Future<List<Language>> sourceLanguages(
    AiProviderConfig config, {
    Object Function()? unlessCached,
  }) async {
    final languages = switch (config.service) {
      MtService.deepl => [
        for (final language in await _deeplList(
          config,
          DeeplLanguageType.source,
          unlessCached: unlessCached,
        ))
          _language(appCodeFromDeepl(language.code), language.name),
      ],
      MtService.libreTranslate => [
        for (final language in await _libreList(
          config,
          unlessCached: unlessCached,
        ))
          _language(appCodeFromLibre(language.code), language.name),
      ],
      MtService.llm => throw _notMt(config),
    };
    return List.unmodifiable([Language.auto, ..._unique(languages)]);
  }

  /// Target languages with app codes (`EN-US` -> `en-US`, `ZH-HANT` ->
  /// `zh-TW`, `PT-BR` -> `pt-BR`). LibreTranslate: every code some language
  /// can be translated into (all languages on servers that do not say).
  /// [unlessCached] as for [sourceLanguages].
  Future<List<Language>> targetLanguages(
    AiProviderConfig config, {
    Object Function()? unlessCached,
  }) async {
    final languages = switch (config.service) {
      MtService.deepl => [
        for (final language in await _deeplList(
          config,
          DeeplLanguageType.target,
          unlessCached: unlessCached,
        ))
          _language(appCodeFromDeepl(language.code), language.name),
      ],
      MtService.libreTranslate => _libreTargets(
        await _libreList(config, unlessCached: unlessCached),
      ),
      MtService.llm => throw _notMt(config),
    };
    return List.unmodifiable(_unique(languages));
  }

  static List<Language> _libreTargets(List<LibreLanguage> languages) {
    final targets = {
      for (final language in languages)
        for (final code in language.targets) code.toLowerCase(),
    };
    return [
      for (final language in languages)
        if (targets.isEmpty || targets.contains(language.code.toLowerCase()))
          _language(appCodeFromLibre(language.code), language.name),
    ];
  }

  static Language _language(String appCode, String name) {
    final code = LanguageMatcher.normalize(appCode);
    final known = LanguageCatalog.byCode(code);
    final trimmed = name.trim();
    return Language(
      code: code,
      name: trimmed.isNotEmpty ? trimmed : known?.name ?? code,
      nativeName: known?.nativeName,
    );
  }

  static List<Language> _unique(List<Language> languages) {
    final seen = <String>{};
    return [
      for (final language in languages)
        if (language.code.isNotEmpty && seen.add(language.code.toLowerCase()))
          language,
    ];
  }

  // Translation.

  /// Translates [request] with the service of [config]; one final result.
  ///
  /// DeepL gets the formality (as `prefer_more` / `prefer_less`, which never
  /// fail for languages without formality support), the free-form context
  /// and `preserve_formatting`; with [xmlTags] `tag_handling=xml` (the text
  /// is XML with `<x i="n"/>` masks, see `TextMasker`), with
  /// [AiProviderConfig.preferQualityModel] the quality-optimised model
  /// (`prefer_quality_optimized`), and a glossary of
  /// `TranslationOptions.glossary` when one of its terms occurs in the text
  /// (see [DeeplGlossaries]; DeepL needs the source language then, so an
  /// auto source is identified with [identifySource] first, on the device,
  /// and the text goes without a glossary when it cannot tell). Codes are
  /// converted with the service's language list when it can be loaded. An
  /// empty translation of a non-blank text is reported as an
  /// [MtApiException]. Completing [abort] cancels the HTTP request.
  Future<TranslationResult> translate(
    TranslationEngine engine,
    AiProviderConfig config,
    TranslationRequest request, {
    Future<void>? abort,
    bool xmlTags = false,
    Future<String?> Function()? identifySource,
  }) async {
    if (request.source.isCustom || request.target.isCustom) {
      final custom = request.source.isCustom ? request.source : request.target;
      throw ArgumentError.value(
        custom.code,
        request.source.isCustom ? 'source' : 'target',
        'Custom languages require an AI engine',
      );
    }
    final stopwatch = Stopwatch()..start();
    final (text, detected) = switch (config.service) {
      MtService.deepl => await _translateDeepl(
        config,
        request,
        abort,
        xmlTags: xmlTags,
        identifySource: identifySource,
      ),
      MtService.libreTranslate => await _translateLibre(config, request, abort),
      MtService.llm => throw _notMt(config),
    };
    if (text.trim().isEmpty) {
      throw MtApiException(
        '${engine.name} returned an empty translation.',
        kind: MtErrorKind.invalidResponse,
      );
    }
    return TranslationResult(
      engineId: engine.id,
      engineName: engine.name,
      text: text,
      detectedSource: request.source.isAuto
          ? normalizeDetected(detected)
          : null,
      elapsed: stopwatch.elapsed,
    );
  }

  Future<(String, String?)> _translateDeepl(
    AiProviderConfig config,
    TranslationRequest request,
    Future<void>? abort, {
    required bool xmlTags,
    Future<String?> Function()? identifySource,
  }) async {
    final targets = await _codesOrNull(
      () => _deeplList(config, DeeplLanguageType.target),
      (language) => language.code,
    );
    final options = request.options;
    final context = options.context.trim();
    final client = _deepl(config);
    var source = request.source.isAuto ? null : request.source.code;
    final glossaryId = await _glossaryFor(
      client,
      config,
      request,
      sourceCode: () async => source ??= await identifySource?.call(),
    );
    // An auto source is only sent (as identified) with a glossary.
    final explicit = request.source.isAuto && glossaryId == null
        ? null
        : source;
    final result = await client.translateText(
      text: request.text,
      targetLang: deeplTargetCode(request.target.code, supported: targets),
      sourceLang: explicit == null ? null : deeplSourceCode(explicit),
      formality: deeplFormality(options.formality),
      context: context.isEmpty ? null : context,
      glossaryId: glossaryId,
      preserveFormatting: options.preserveFormatting,
      tagHandling: xmlTags ? DeeplTagHandling.xml : null,
      modelType: config.preferQualityModel
          ? DeeplModelType.preferQualityOptimized
          : null,
      abortTrigger: abort,
    );
    final detected = result.detectedSourceLanguage.trim();
    return (result.text, detected.isEmpty ? null : appCodeFromDeepl(detected));
  }

  /// The id of the DeepL glossary for [request] (see [translate]), or null
  /// when none of its glossary's terms occurs in the text, the source
  /// language ([sourceCode]) is unknown or the glossary cannot be made.
  Future<String?> _glossaryFor(
    DeeplClient client,
    AiProviderConfig config,
    TranslationRequest request, {
    required Future<String?> Function() sourceCode,
  }) async {
    final entries = DeeplGlossaries.validEntries(request.options.glossary);
    if (entries.isEmpty) return null;
    final text = request.text.toLowerCase();
    if (!entries.keys.any((term) => text.contains(term.toLowerCase()))) {
      return null;
    }
    final String? source;
    try {
      source = await sourceCode();
    } on Object {
      return null;
    }
    if (source == null) return null;
    return await glossaries.idFor(
      client,
      connection: connectionKey(config),
      sourceLanguage: source,
      targetLanguage: request.target.code,
      entries: entries,
    );
  }

  Future<(String, String?)> _translateLibre(
    AiProviderConfig config,
    TranslationRequest request,
    Future<void>? abort,
  ) async {
    final codes = await _codesOrNull(
      () => _libreList(config),
      (language) => language.code,
    );
    final result = await _libre(config).translate(
      text: request.text,
      source: request.source.isAuto
          ? 'auto'
          : libreLanguageCode(request.source.code, supported: codes),
      target: libreLanguageCode(request.target.code, supported: codes),
      abortTrigger: abort,
    );
    final detected = result.detectedLanguage?.code.trim() ?? '';
    return (result.text, detected.isEmpty ? null : appCodeFromLibre(detected));
  }

  /// The service codes of a language list, or null when it cannot be loaded
  /// (the code helpers then use their defaults).
  static Future<List<String>?> _codesOrNull<T>(
    Future<List<T>> Function() load,
    String Function(T) code,
  ) async {
    try {
      return [for (final language in await load()) code(language)];
    } on MtApiException {
      return null;
    }
  }

  /// The DeepL `formality` value for [formality] (null for automatic).
  static String? deeplFormality(Formality formality) => switch (formality) {
    Formality.automatic => null,
    Formality.more || Formality.preferMore => DeeplFormality.preferMore,
    Formality.less || Formality.preferLess => DeeplFormality.preferLess,
  };

  /// Translates "Hello, world!" to French with a temporary client (for a
  /// provider that may still be edited); returns the translation.
  Future<String> test(AiProviderConfig config) async {
    switch (config.service) {
      case MtService.deepl:
        final client = _deeplBuilder(config);
        try {
          final result = await client.translateText(
            text: 'Hello, world!',
            sourceLang: 'EN',
            targetLang: 'FR',
          );
          return _nonEmpty(result.text, config);
        } finally {
          client.close();
        }
      case MtService.libreTranslate:
        final client = _libreBuilder(config);
        try {
          final result = await client.translate(
            text: 'Hello, world!',
            source: 'en',
            target: 'fr',
          );
          return _nonEmpty(result.text, config);
        } finally {
          client.close();
        }
      case MtService.llm:
        throw _notMt(config);
    }
  }

  static String _nonEmpty(String text, AiProviderConfig config) {
    if (text.trim().isEmpty) {
      throw MtApiException(
        '${config.name} returned an empty translation.',
        kind: MtErrorKind.invalidResponse,
      );
    }
    return text;
  }

  static ArgumentError _notMt(AiProviderConfig config) => ArgumentError.value(
    config.id,
    'config',
    'Not a machine translation service',
  );

  static String _withScheme(String url) {
    var u = url;
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u.contains('://') ? u : 'https://$u';
  }
}
