import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mt_api/src/libre/libre_models.dart';
import 'package:mt_api/src/mt_api_exception.dart';
import 'package:mt_api/src/mt_transport.dart';

/// Client for a LibreTranslate server (https://libretranslate.com or a
/// self-hosted instance, see https://docs.libretranslate.com).
///
/// * `POST /translate`, `POST /detect` take JSON bodies; [apiKey] is sent as
///   the `api_key` member when set.
/// * `GET /languages` lists languages with their possible targets.
/// * `GET /frontend/settings` tells whether a key is required and the
///   character limit.
/// * Errors are `{"error": "..."}` with status 400 (invalid request; also
///   "Visit ... to get an API key" on servers that need one), 403 (invalid
///   key), 429 (rate limit) or 500 (translation failed).
///
/// LibreTranslate enables CORS by default, so the client also works on the
/// web. Every method throws [LibreTranslateException] on failure.
class LibreTranslateClient {
  new({
    required this.baseUrl,
    String? apiKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : apiKey = switch (apiKey?.trim()) {
         final key? when key.isNotEmpty => key,
         _ => null,
       } {
    _transport = MtTransport(
      service: 'LibreTranslate',
      timeout: timeout,
      httpClient: httpClient,
      newException: LibreTranslateException.new,
      mapHttpError: _httpError,
    );
  }

  /// The public instance run by the LibreTranslate authors (needs a key).
  static final Uri officialBaseUrl = Uri.parse('https://libretranslate.com');

  /// Where users get a key for [officialBaseUrl].
  static const String apiKeyUrl = 'https://portal.libretranslate.com';

  static final _schemePattern = RegExp(
    '^[a-z][a-z0-9+.-]*://',
    caseSensitive: false,
  );

  static final _hostPattern = RegExp(r'^[a-z0-9_-]+(\.[a-z0-9_-]+)*$');

  /// Endpoint names users sometimes paste along with the server URL.
  static const _endpointNames = {
    'translate',
    'languages',
    'detect',
    'translate_file',
    'docs',
  };

  /// Turns user input into a canonical base URL: trims it, adds `http://`
  /// for local hosts (`localhost`, private IPv4 ranges, `*.local`, `*.lan`,
  /// `*.internal`, `*.home.arpa`, single-label names) and `https://`
  /// otherwise, drops query and fragment, empty path segments and a pasted
  /// endpoint name (`/translate`, `/languages`, ...).
  ///
  /// Throws [FormatException] when the input cannot be a server URL.
  static Uri normalizeBaseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('The server URL is empty');
    }
    final hasScheme = _schemePattern.hasMatch(trimmed);
    final Uri parsed;
    try {
      parsed = Uri.parse(hasScheme ? trimmed : '//$trimmed');
    } on FormatException {
      throw FormatException('Not a valid URL', input);
    }
    final host = parsed.host;
    if (host.isEmpty || (!host.contains(':') && !_hostPattern.hasMatch(host))) {
      throw FormatException('Not a valid host name', input);
    }
    final scheme = hasScheme
        ? parsed.scheme.toLowerCase()
        : (_isLocalHost(host) ? 'http' : 'https');
    if (scheme != 'http' && scheme != 'https') {
      throw FormatException('Only http and https URLs are supported', input);
    }
    final segments = [
      for (final segment in parsed.pathSegments)
        if (segment.isNotEmpty) segment,
    ];
    if (segments.isNotEmpty && _endpointNames.contains(segments.last)) {
      segments.removeLast();
    }
    return Uri(
      scheme: scheme,
      userInfo: parsed.userInfo.isEmpty ? null : parsed.userInfo,
      host: host,
      port: parsed.hasPort ? parsed.port : null,
      pathSegments: segments,
    );
  }

  static bool _isLocalHost(String host) {
    if (host.contains(':')) {
      return host == '::1' || host.startsWith('fc') || host.startsWith('fd');
    }
    const suffixes = [
      '.local',
      '.localhost',
      '.lan',
      '.internal',
      '.home.arpa',
    ];
    if (!host.contains('.') || suffixes.any(host.endsWith)) return true;
    return switch (host.split('.').map(int.tryParse).toList()) {
      [10 || 127, int(), int(), int()] => true,
      [192, 168, int(), int()] || [169, 254, int(), int()] => true,
      [172, final int b, int(), int()] when b >= 16 && b <= 31 => true,
      [100, final int b, int(), int()] when b >= 64 && b <= 127 => true,
      _ => false,
    };
  }

  /// Root of the server, e.g. `https://translate.example.com` (sub-paths
  /// are kept).
  final Uri baseUrl;

  /// `null` when no key is configured.
  final String? apiKey;

  /// Upper bound for each request, until the whole response has arrived.
  final Duration timeout;
  late final MtTransport _transport;

  /// `POST /translate` for one [text]. [source] may be `auto`; then
  /// [LibreTranslation.detectedLanguage] is set. [format] is one of
  /// [LibreFormat.values]. [alternatives] > 0 requests that many
  /// alternative translations (servers may return fewer). Completing
  /// [abortTrigger] cancels the request.
  Future<LibreTranslation> translate({
    required String text,
    required String target,
    String source = 'auto',
    String format = LibreFormat.text,
    int alternatives = 0,
    Future<void>? abortTrigger,
  }) async {
    final uri = _endpoint('translate');
    final json = _transport.expectObject(
      await _transport.sendJson(
        'POST',
        uri,
        json: _translateBody(text, source, target, format, alternatives),
        abortTrigger: abortTrigger,
      ),
      uri,
    );
    if (json['translatedText'] is! String) {
      throw _transport.invalidResponse(uri, 'missing translatedText');
    }
    return LibreTranslation.fromJson(json);
  }

  /// `POST /translate` with a list `q`: one [LibreTranslation] per text, in
  /// order. An empty [texts] list returns `[]` without a request.
  Future<List<LibreTranslation>> translateBatch({
    required List<String> texts,
    required String target,
    String source = 'auto',
    String format = LibreFormat.text,
    int alternatives = 0,
    Future<void>? abortTrigger,
  }) async {
    if (texts.isEmpty) return const [];
    final uri = _endpoint('translate');
    final json = _transport.expectObject(
      await _transport.sendJson(
        'POST',
        uri,
        json: _translateBody(texts, source, target, format, alternatives),
        abortTrigger: abortTrigger,
      ),
      uri,
    );
    final translated = _transport.expectList(json['translatedText'], uri);
    if (translated.length != texts.length) {
      throw _transport.invalidResponse(
        uri,
        'expected ${texts.length} translations, got ${translated.length}',
      );
    }
    final detected = json['detectedLanguage'];
    final alternativeLists = json['alternatives'];
    return List.unmodifiable([
      for (var i = 0; i < translated.length; i++)
        LibreTranslation.fromJson({
          'translatedText': translated[i],
          'detectedLanguage': ?_at(detected, i),
          'alternatives': ?_at(alternativeLists, i),
        }),
    ]);
  }

  /// `GET /languages`.
  Future<List<LibreLanguage>> languages() async {
    final uri = _endpoint('languages');
    final json = await _transport.sendJson('GET', uri);
    return List.unmodifiable([
      for (final item in _transport.expectList(json, uri))
        if (item is Map<String, dynamic>) LibreLanguage.fromJson(item),
    ]);
  }

  /// `POST /detect`: candidate languages, most likely first.
  Future<List<LibreDetectedLanguage>> detect(String text) async {
    final uri = _endpoint('detect');
    final json = await _transport.sendJson(
      'POST',
      uri,
      json: {'q': text, 'api_key': ?apiKey},
    );
    return List.unmodifiable([
      for (final item in _transport.expectList(json, uri))
        if (item is Map<String, dynamic>) LibreDetectedLanguage.fromJson(item),
    ]);
  }

  /// `GET /frontend/settings`. Cheap; also a good "test connection" call
  /// (combine with [translate] to validate a key).
  Future<LibreSettings> settings() async {
    final uri = _endpoint('frontend', 'settings');
    return LibreSettings.fromJson(
      _transport.expectObject(await _transport.sendJson('GET', uri), uri),
    );
  }

  /// Closes the underlying HTTP client if this instance created it.
  void close() => _transport.close();

  Map<String, Object> _translateBody(
    Object q,
    String source,
    String target,
    String format,
    int alternatives,
  ) {
    final from = source.trim();
    return {
      'q': q,
      'source': from.isEmpty ? 'auto' : from,
      'target': target.trim(),
      'format': format,
      if (alternatives > 0) 'alternatives': alternatives,
      'api_key': ?apiKey,
    };
  }

  static Object? _at(Object? list, int index) =>
      list is List && index < list.length ? list[index] : null;

  Uri _endpoint(String name, [String? subName]) => Uri(
    scheme: baseUrl.scheme,
    userInfo: baseUrl.userInfo.isEmpty ? null : baseUrl.userInfo,
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
    pathSegments: [
      for (final segment in baseUrl.pathSegments)
        if (segment.isNotEmpty) segment,
      name,
      ?subName,
    ],
  );

  static MtApiException _httpError(http.Response response, Uri uri) {
    final status = response.statusCode;
    final detail = MtTransport.serverMessage(response);
    final lower = detail?.toLowerCase() ?? '';
    final kind = switch (MtErrorKind.fromStatus(status)) {
      // libretranslate.com answers 400 "Visit https://portal... to get an
      // API key" when the key is missing.
      MtErrorKind.badRequest when lower.contains('api key') =>
        MtErrorKind.unauthorized,
      // "Invalid request: request (6000) exceeds text limit (5000)".
      MtErrorKind.badRequest when lower.contains('exceeds') =>
        MtErrorKind.payloadTooLarge,
      final kind => kind,
    };
    final message = switch (kind) {
      MtErrorKind.badRequest =>
        'The LibreTranslate server rejected the '
            'request.',
      MtErrorKind.unauthorized when status == 400 =>
        'This LibreTranslate server requires an API key.',
      MtErrorKind.unauthorized =>
        'Invalid API key for this LibreTranslate server.',
      MtErrorKind.notFound => 'Not found. Check the LibreTranslate server URL.',
      MtErrorKind.payloadTooLarge =>
        'The text is longer than this LibreTranslate server allows.',
      MtErrorKind.rateLimited =>
        'Too many requests to the LibreTranslate server. Wait a moment and '
            'try again.',
      MtErrorKind.server => 'The LibreTranslate server failed to translate.',
      _ => 'LibreTranslate request failed (HTTP $status).',
    };
    return LibreTranslateException(
      message,
      kind: kind,
      statusCode: status,
      detail: detail,
      uri: uri,
    );
  }
}
