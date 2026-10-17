import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mt_api/src/deepl/deepl_models.dart';
import 'package:mt_api/src/mt_api_exception.dart';
import 'package:mt_api/src/mt_transport.dart';

/// Client for the DeepL API v2 (https://developers.deepl.com/docs).
///
/// * Free keys end in `:fx` and use `https://api-free.deepl.com`; other keys
///   use `https://api.deepl.com`. A custom [baseUrl] (e.g. a proxy) wins.
/// * Every request sends `Authorization: DeepL-Auth-Key <key>`; bodies are
///   JSON.
/// * Language codes are DeepL codes (see `deeplTargetCode`,
///   `deeplSourceCode` and `appCodeFromDeepl` to convert app codes).
/// * The DeepL API does not allow cross-origin browser requests, so on the
///   web requests fail with [MtErrorKind.network] unless [baseUrl] points to
///   a CORS-enabled proxy.
///
/// Every method throws [DeeplApiException] on failure.
class DeeplClient {
  new({
    required String authKey,
    Uri? baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : authKey = authKey.trim(),
       baseUrl = baseUrl ?? defaultBaseUrl(authKey) {
    _transport = MtTransport(
      service: 'DeepL',
      timeout: timeout,
      httpClient: httpClient,
      newException: DeeplApiException.new,
      mapHttpError: _httpError,
    );
  }

  static final Uri freeBaseUrl = Uri.parse('https://api-free.deepl.com');
  static final Uri proBaseUrl = Uri.parse('https://api.deepl.com');

  /// Where users create a (free) API key.
  static const String apiKeyUrl = 'https://www.deepl.com/your-account/keys';

  /// DeepL accepts at most this many texts per translate request;
  /// [translate] splits longer lists into several requests.
  static const int maxTextsPerRequest = 50;

  /// Whether [authKey] belongs to a DeepL API Free account.
  static bool isFreeKey(String authKey) => authKey.trim().endsWith(':fx');

  /// [freeBaseUrl] for free keys, otherwise [proBaseUrl].
  static Uri defaultBaseUrl(String authKey) =>
      isFreeKey(authKey) ? freeBaseUrl : proBaseUrl;

  final String authKey;
  final Uri baseUrl;

  /// Upper bound for each request, until the whole response has arrived.
  final Duration timeout;
  late final MtTransport _transport;

  /// `POST /v2/translate`. Returns one [DeeplTranslation] per text, in
  /// order. Only the texts that are not blank are sent (they are not
  /// billed either way, but need no round trip); blank ones are answered as
  /// they are, and an empty or all-blank [texts] list makes no request.
  ///
  /// [sourceLang] `null`, empty or `auto` lets DeepL detect the language.
  /// [formality] is one of [DeeplFormality.values], [tagHandling] one of
  /// [DeeplTagHandling.values] and [modelType] one of
  /// [DeeplModelType.values]. [context] is extra text that influences the
  /// translation but is not translated (not billed). Completing
  /// [abortTrigger] cancels the request.
  Future<List<DeeplTranslation>> translate({
    required List<String> texts,
    required String targetLang,
    String? sourceLang,
    String? formality,
    String? context,
    String? glossaryId,
    bool preserveFormatting = false,
    String? tagHandling,
    String? modelType,
    Future<void>? abortTrigger,
  }) async {
    final source = sourceLang?.trim() ?? '';
    final options = <String, Object>{
      'target_lang': targetLang.trim(),
      if (source.isNotEmpty && source.toLowerCase() != 'auto')
        'source_lang': source,
      if (formality != null && formality.isNotEmpty) 'formality': formality,
      if (context != null && context.trim().isNotEmpty) 'context': context,
      if (glossaryId != null && glossaryId.isNotEmpty)
        'glossary_id': glossaryId,
      if (preserveFormatting) 'preserve_formatting': true,
      if (tagHandling != null && tagHandling.isNotEmpty)
        'tag_handling': tagHandling,
      if (modelType != null && modelType.isNotEmpty) 'model_type': modelType,
    };
    final uri = _endpoint(const ['translate']);
    final results = [
      for (final text in texts)
        DeeplTranslation(text: text, detectedSourceLanguage: ''),
    ];
    final sent = [
      for (var i = 0; i < texts.length; i++)
        if (texts[i].trim().isNotEmpty) i,
    ];
    for (var start = 0; start < sent.length; start += maxTextsPerRequest) {
      final end = start + maxTextsPerRequest < sent.length
          ? start + maxTextsPerRequest
          : sent.length;
      final indices = sent.sublist(start, end);
      final batch = [for (final i in indices) texts[i]];
      final json = _transport.expectObject(
        await _transport.sendJson(
          'POST',
          uri,
          headers: _headers,
          json: {'text': batch, ...options},
          abortTrigger: abortTrigger,
        ),
        uri,
      );
      final translations = _transport.expectList(json['translations'], uri);
      if (translations.length != batch.length) {
        throw _transport.invalidResponse(
          uri,
          'expected ${batch.length} translations, got '
          '${translations.length}',
        );
      }
      for (var j = 0; j < indices.length; j++) {
        results[indices[j]] = DeeplTranslation.fromJson(
          _transport.expectObject(translations[j], uri),
        );
      }
    }
    return List.unmodifiable(results);
  }

  /// Translates a single [text]; see [translate].
  Future<DeeplTranslation> translateText({
    required String text,
    required String targetLang,
    String? sourceLang,
    String? formality,
    String? context,
    String? glossaryId,
    bool preserveFormatting = false,
    String? tagHandling,
    String? modelType,
    Future<void>? abortTrigger,
  }) async => (await translate(
    texts: [text],
    targetLang: targetLang,
    sourceLang: sourceLang,
    formality: formality,
    context: context,
    glossaryId: glossaryId,
    preserveFormatting: preserveFormatting,
    tagHandling: tagHandling,
    modelType: modelType,
    abortTrigger: abortTrigger,
  )).single;

  /// `GET /v2/languages?type=source|target`.
  Future<List<DeeplLanguage>> languages({
    DeeplLanguageType type = DeeplLanguageType.target,
  }) async {
    final uri = _endpoint(const ['languages'], {'type': type.name});
    final json = await _transport.sendJson('GET', uri, headers: _headers);
    return List.unmodifiable([
      for (final item in _transport.expectList(json, uri))
        if (item is Map<String, dynamic>) DeeplLanguage.fromJson(item),
    ]);
  }

  /// `GET /v2/usage`. Cheap; also a good "test connection" call.
  Future<DeeplUsage> usage() async {
    final uri = _endpoint(const ['usage']);
    return DeeplUsage.fromJson(
      _transport.expectObject(
        await _transport.sendJson('GET', uri, headers: _headers),
        uri,
      ),
    );
  }

  /// `POST /v2/glossaries` with TSV [entries] (source term -> target term).
  ///
  /// [sourceLang]/[targetLang] may be any DeepL or app code; glossaries use
  /// bare lower-case languages, so `EN-US` is sent as `en`. Terms are
  /// trimmed. Throws [ArgumentError] when [entries] is empty or a term is
  /// empty or contains a tab, line break or other control character.
  Future<DeeplGlossary> createGlossary({
    required String name,
    required String sourceLang,
    required String targetLang,
    required Map<String, String> entries,
  }) async {
    final uri = _endpoint(const ['glossaries']);
    final json = await _transport.sendJson(
      'POST',
      uri,
      headers: _headers,
      json: {
        'name': name,
        'source_lang': glossaryLanguage(sourceLang),
        'target_lang': glossaryLanguage(targetLang),
        'entries': glossaryTsv(entries),
        'entries_format': 'tsv',
      },
    );
    return DeeplGlossary.fromJson(_transport.expectObject(json, uri));
  }

  /// `GET /v2/glossaries`.
  Future<List<DeeplGlossary>> listGlossaries() async {
    final uri = _endpoint(const ['glossaries']);
    final json = _transport.expectObject(
      await _transport.sendJson('GET', uri, headers: _headers),
      uri,
    );
    return List.unmodifiable([
      for (final item in _transport.expectList(json['glossaries'], uri))
        if (item is Map<String, dynamic>) DeeplGlossary.fromJson(item),
    ]);
  }

  /// `GET /v2/glossaries/<id>`.
  Future<DeeplGlossary> getGlossary(String glossaryId) async {
    final uri = _endpoint(['glossaries', glossaryId]);
    return DeeplGlossary.fromJson(
      _transport.expectObject(
        await _transport.sendJson('GET', uri, headers: _headers),
        uri,
      ),
    );
  }

  /// `GET /v2/glossaries/<id>/entries` (TSV), parsed into a map.
  Future<Map<String, String>> glossaryEntries(String glossaryId) async {
    final uri = _endpoint(['glossaries', glossaryId, 'entries']);
    final response = await _transport.send(
      'GET',
      uri,
      headers: {..._headers, 'accept': 'text/tab-separated-values'},
    );
    return parseGlossaryTsv(MtTransport.bodyText(response));
  }

  /// `DELETE /v2/glossaries/<id>` (HTTP 204).
  Future<void> deleteGlossary(String glossaryId) async {
    final uri = _endpoint(['glossaries', glossaryId]);
    await _transport.send('DELETE', uri, headers: _headers);
  }

  /// `GET /v2/glossary-language-pairs`.
  Future<List<DeeplGlossaryLanguagePair>> glossaryLanguagePairs() async {
    final uri = _endpoint(const ['glossary-language-pairs']);
    final json = _transport.expectObject(
      await _transport.sendJson('GET', uri, headers: _headers),
      uri,
    );
    return List.unmodifiable([
      for (final item in _transport.expectList(
        json['supported_languages'],
        uri,
      ))
        if (item is Map<String, dynamic>)
          DeeplGlossaryLanguagePair.fromJson(item),
    ]);
  }

  /// Closes the underlying HTTP client if this instance created it.
  void close() => _transport.close();

  /// The bare lower-case language glossaries use: `EN-US` -> `en`,
  /// `zh-TW` -> `zh`, `no` -> `nb`.
  static String glossaryLanguage(String code) {
    final language = code.trim().toLowerCase().split(RegExp('[-_]')).first;
    return switch (language) {
      'no' => 'nb',
      'iw' => 'he',
      _ => language,
    };
  }

  static final _forbiddenInTerm = RegExp(r'[\x00-\x1F\x7F-\x9F  ]');

  /// Encodes [entries] as DeepL glossary TSV (`source\ttarget` lines).
  /// See [createGlossary] for the validation rules.
  static String glossaryTsv(Map<String, String> entries) {
    if (entries.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'Must not be empty');
    }
    String term(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || _forbiddenInTerm.hasMatch(trimmed)) {
        throw ArgumentError.value(
          value,
          'entries',
          'Glossary terms must be non-empty and contain no tabs, line breaks '
              'or control characters',
        );
      }
      return trimmed;
    }

    return [
      for (final MapEntry(:key, :value) in entries.entries)
        '${term(key)}\t${term(value)}',
    ].join('\n');
  }

  /// Parses glossary TSV (blank lines and lines without a tab are skipped).
  static Map<String, String> parseGlossaryTsv(String tsv) => {
    for (final line in tsv.split(RegExp(r'\r?\n')))
      if (line.indexOf('\t') case final tab when tab > 0)
        line.substring(0, tab).trim(): line.substring(tab + 1).trim(),
  };

  Map<String, String> get _headers => {
    'authorization': 'DeepL-Auth-Key $authKey',
  };

  /// `<baseUrl>/v2/<segments>`, keeping any sub-path of [baseUrl].
  Uri _endpoint(List<String> segments, [Map<String, String>? query]) => Uri(
    scheme: baseUrl.scheme,
    userInfo: baseUrl.userInfo.isEmpty ? null : baseUrl.userInfo,
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
    pathSegments: [
      for (final segment in baseUrl.pathSegments)
        if (segment.isNotEmpty) segment,
      'v2',
      ...segments,
    ],
    queryParameters: query,
  );

  static MtApiException _httpError(http.Response response, Uri uri) {
    final status = response.statusCode;
    final kind = MtErrorKind.fromStatus(status);
    final message = switch (kind) {
      MtErrorKind.badRequest => 'DeepL rejected the request.',
      MtErrorKind.unauthorized =>
        'Authorization failed. Check your DeepL API key.',
      MtErrorKind.notFound => 'Not found. The glossary may have been deleted.',
      MtErrorKind.payloadTooLarge =>
        'The request is too large. Translate a shorter text.',
      MtErrorKind.rateLimited =>
        'Too many requests to DeepL. Wait a moment and try again.',
      MtErrorKind.quotaExceeded =>
        'DeepL quota exceeded: the character limit for this billing period '
            'has been reached.',
      MtErrorKind.server =>
        'DeepL is temporarily unavailable. Try again later.',
      _ => 'DeepL request failed (HTTP $status).',
    };
    return DeeplApiException(
      message,
      kind: kind,
      statusCode: status,
      detail: MtTransport.serverMessage(response),
      uri: uri,
    );
  }
}
