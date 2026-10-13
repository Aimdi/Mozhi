import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mozhi_api/src/models/models.dart';
import 'package:mozhi_api/src/mozhi_api_exception.dart';

/// Builds one attempt of a request to [url] that is aborted when
/// [abortTrigger] completes. Called again for every redirect hop, because a
/// request (and its multipart files) can only be sent once.
typedef _RequestBuilder = http.BaseRequest Function(
  Uri url,
  Future<void> abortTrigger,
);

/// Client for one Mozhi instance.
///
/// Mozhi API facts (from the Go source, `serve/serve.go` + `pages/api.go`):
/// * All endpoints live under `<base>/api/...` and send
///   `Access-Control-Allow-Origin: *`.
/// * `GET /api/engines` -> `{"all": "All Engines", "some": "Some Engines",
///   "google": "Google", "deepl": "DeepL", ...}` (disabled engines are
///   omitted). `all` and `some` are pseudo-engines.
/// * `GET /api/source_languages?engine=X` and `/api/target_languages?engine=X`
///   -> `[{"Name": "...", "Id": "..."}]`.
/// * `/api/translate` accepts GET query params or POST form fields
///   `engine`, `from`, `to`, `text` (all required). Use POST
///   (`application/x-www-form-urlencoded`) so long texts do not hit URL
///   limits. `engine=all` or a comma separated list (`google,deepl`) returns
///   a JSON array (engines that fail are silently dropped, order is random);
///   a single engine returns one object.
/// * `GET /api/tts?engine=google|reverso&lang=en&text=...` -> `audio/mpeg`.
/// * `POST /api/image` multipart form: `engine`, `from`, `to`, and file field
///   `image` whose part Content-Type MUST be `image/png`.
/// * `GET /api/version` -> `{"fiberversion": ..., "goversion": ...}`.
/// * Errors: non-2xx status with a plain-text body (Fiber default handler),
///   e.g. 400 "from, to, engine, text are required query strings." or 500
///   "Engine does not exist or has been disabled.".
///
/// Every method throws [MozhiApiException] on failure: HTTP errors carry the
/// status code; transport failures, timeouts and malformed bodies do not.
/// The exception's `uri` is the last URL that was requested, which differs
/// from the endpoint after a redirect.
///
/// POST requests (`translate*`) are never redirected by the platform: a
/// 301, 302, 307 or 308 answer (typically a reverse proxy upgrading `http`
/// to `https`) is followed here by re-sending the same form to `Location`,
/// at most [maxRedirects] times and never from `https` to `http`. On the web
/// a redirected POST therefore fails as a transport error, because `fetch`
/// can only follow it as a GET without the form.
class MozhiApiClient {
  new({
    required this.baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _authorization = _basicAuthorization(baseUrl.userInfo);

  /// Root of the instance, e.g. `https://mozhi.aryak.me` or
  /// `http://192.168.1.10:3000/mozhi` (sub-path deployments are allowed).
  ///
  /// Percent-encoded user info (`https://me:p%40ss@host`) is decoded and
  /// sent as a basic `Authorization` header to this origin only, never as
  /// part of a request URL. On the web this needs a reverse proxy that
  /// answers the CORS preflight the header triggers; Mozhi itself does not.
  final Uri baseUrl;

  /// Upper bound for each request, from sending it until the whole response
  /// body has arrived, including any redirect hops. The request is aborted
  /// when it runs out, so it does not keep uploading or downloading.
  final Duration timeout;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// `Basic ...` credentials from the user info of [baseUrl], if any.
  final String? _authorization;

  /// How many redirects a request follows before failing with the 3xx.
  static const maxRedirects = 3;

  /// Statuses after which the same request is sent again to `Location`.
  /// 303 is not one of them: it asks for a GET, which would drop the form.
  static const _redirectStatuses = {301, 302, 307, 308};

  /// Ids returned by `/api/engines` that are not real engines.
  static const _pseudoEngines = {'all', 'some'};

  static final _schemePattern = RegExp(
    '^[a-z][a-z0-9+.-]*://',
    caseSensitive: false,
  );

  /// Dot-separated labels; `_` is allowed for Docker-style service names.
  static final _hostNamePattern = RegExp(r'^[a-z0-9_-]+(\.[a-z0-9_-]+)*$');

  /// Suffixes of names that only resolve on a LAN or an overlay network,
  /// where instances rarely have TLS certificates.
  static const _plainHttpSuffixes = [
    '.local',
    '.localhost',
    '.lan',
    '.internal',
    '.home.arpa',
    '.onion',
    '.i2p',
  ];

  /// Turns user input into a canonical base URL:
  /// trims whitespace, adds `https://` when no scheme is given (but `http://`
  /// for `localhost`, `127.*`, `10.*`, `192.168.*`, `172.16-31.*` and
  /// `*.local` hosts), drops query/fragment, strips a trailing `/` and a
  /// trailing `/api` segment.
  ///
  /// `http://` is likewise inferred for other hosts that are not publicly
  /// routable: single-label names (`raspberrypi`), `169.254.*`, CGNAT /
  /// Tailscale `100.64-127.*`, IPv6 loopback, unique-local and link-local
  /// addresses, `*.localhost`, `*.lan`, `*.internal`, `*.home.arpa`, and
  /// the Tor/I2P `*.onion` and `*.i2p` names. An explicit scheme is kept,
  /// as are user info, the port and any sub-path; the host is lowercased
  /// and empty path segments are dropped.
  ///
  /// Credentials for basic auth (`https://me:secret@host`) are kept
  /// percent-encoded: a password containing `@`, `#`, `/`, `?`, `%` or a
  /// space must be typed encoded (`p%40ss`); requests send it decoded.
  ///
  /// Throws [FormatException] when the input cannot be a URL.
  static Uri normalizeBaseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('The instance URL is empty');
    }
    final hasScheme = _schemePattern.hasMatch(trimmed);
    // Without a scheme, parse as a network-path reference (`//host:port`) so
    // that `localhost:3000` is not read as scheme `localhost`.
    final parsed = Uri.parse(hasScheme ? trimmed : '//$trimmed');
    final host = parsed.host;
    // Uri.parse percent-encodes characters that are invalid in a host
    // instead of rejecting them. IPv6 literals (the only hosts containing
    // `:`) have already been validated by it.
    if (!host.contains(':') && !_hostNamePattern.hasMatch(host)) {
      throw FormatException('Not a valid host name', input);
    }
    if (parsed.hasPort && (parsed.port < 1 || parsed.port > 65535)) {
      throw FormatException('Port must be between 1 and 65535', input);
    }
    final scheme = hasScheme
        ? parsed.scheme
        : (_prefersPlainHttp(host) ? 'http' : 'https');
    if (scheme != 'http' && scheme != 'https') {
      throw FormatException('Only http and https URLs are supported', input);
    }
    final segments = [
      for (final segment in parsed.pathSegments)
        if (segment.isNotEmpty) segment,
    ];
    if (segments.lastOrNull == 'api') segments.removeLast();
    return Uri(
      scheme: scheme,
      userInfo: parsed.userInfo,
      host: host,
      port: parsed.hasPort ? parsed.port : null,
      pathSegments: segments,
    );
  }

  /// Whether [host] (lowercase, IPv6 without brackets) is unlikely to serve
  /// HTTPS because it is not reachable from the public internet.
  static bool _prefersPlainHttp(String host) {
    if (host.contains(':')) {
      return host == '::1' ||
          host.startsWith('fc') ||
          host.startsWith('fd') ||
          host.startsWith('fe80:');
    }
    if (!host.contains('.') || _plainHttpSuffixes.any(host.endsWith)) {
      return true;
    }
    return switch (host.split('.').map(int.tryParse).toList()) {
      [10 || 127, int(), int(), int()] => true,
      [192, 168, int(), int()] || [169, 254, int(), int()] => true,
      [172, final int b, int(), int()] when b >= 16 && b <= 31 => true,
      [100, final int b, int(), int()] when b >= 64 && b <= 127 => true,
      _ => false,
    };
  }

  /// `GET /api/engines`. Returns engine id -> display name, *excluding* the
  /// `all` and `some` pseudo-engines, sorted by display name.
  Future<Map<String, String>> getEngines() async {
    final (url, body) = await _getJson(_endpoint('engines'));
    final json = _expectObject(body, url);
    final engines =
        [
          for (final MapEntry(key: id, :value) in json.entries)
            if (!_pseudoEngines.contains(id))
              (id: id, name: value is String && value.isNotEmpty ? value : id),
        ]..sort((a, b) {
          final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return byName != 0 ? byName : a.id.compareTo(b.id);
        });
    // Map literals are insertion-ordered (LinkedHashMap).
    return {for (final (:id, :name) in engines) id: name};
  }

  /// `GET /api/source_languages?engine=<engine>`.
  Future<List<MozhiLanguage>> getSourceLanguages(String engine) =>
      _getLanguages('source_languages', engine);

  /// `GET /api/target_languages?engine=<engine>`.
  Future<List<MozhiLanguage>> getTargetLanguages(String engine) =>
      _getLanguages('target_languages', engine);

  /// Translates [text] with a single [engine] (POST form).
  Future<MozhiTranslation> translate({
    required String engine,
    required String from,
    required String to,
    required String text,
  }) async {
    final (uri, translations) = await _postTranslate(
      engine: engine,
      from: from,
      to: to,
      text: text,
    );
    if (translations.isEmpty) {
      throw MozhiApiException('$engine returned no translation', uri: uri);
    }
    return translations.first;
  }

  /// Translates with several engines in one request. An empty [engines]
  /// list means every engine (`engine=all`); otherwise the ids are joined
  /// with commas. Always returns a list (a single-object response is
  /// wrapped).
  Future<List<MozhiTranslation>> translateWithEngines({
    required List<String> engines,
    required String from,
    required String to,
    required String text,
  }) async {
    final (_, translations) = await _postTranslate(
      engine: engines.isEmpty ? 'all' : engines.join(','),
      from: from,
      to: to,
      text: text,
    );
    return translations;
  }

  /// `GET /api/tts`. Only `google` and `reverso` support TTS. Returns the
  /// MP3 bytes. Throws [MozhiApiException] when the body is empty.
  Future<Uint8List> textToSpeech({
    required String engine,
    required String language,
    required String text,
  }) async {
    final uri = _endpoint('tts', {
      'engine': engine,
      'lang': language,
      'text': text,
    });
    final (url, response) = await _send(uri, _get);
    if (response.bodyBytes.isEmpty) {
      throw MozhiApiException('$engine returned no audio', uri: url);
    }
    return response.bodyBytes;
  }

  /// `POST /api/image` (multipart). [pngBytes] must be a PNG image; only the
  /// Google engine is implemented server-side.
  Future<MozhiImageTranslation> translateImage({
    required Uint8List pngBytes,
    required String from,
    required String to,
    String engine = 'google',
  }) async {
    final (url, response) = await _send(
      _endpoint('image'),
      (url, abortTrigger) =>
          http.AbortableMultipartRequest(
              'POST',
              url,
              abortTrigger: abortTrigger,
            )
            ..followRedirects = false
            ..fields.addAll({'engine': engine, 'from': from, 'to': to})
            ..files.add(
              http.MultipartFile.fromBytes(
                'image',
                pngBytes,
                filename: 'image.png',
                contentType: MediaType('image', 'png'),
              ),
            ),
    );
    return MozhiImageTranslation.fromJson(
      _expectObject(_decodeJson(response, url), url),
    );
  }

  /// `GET /api/version`. Cheap; used as a health check.
  Future<MozhiVersion> getVersion() async {
    final (url, json) = await _getJson(_endpoint('version'));
    return MozhiVersion.fromJson(_expectObject(json, url));
  }

  /// Measures round-trip latency of [getVersion]. Throws on failure.
  Future<Duration> ping() async {
    final stopwatch = Stopwatch()..start();
    await getVersion();
    return stopwatch.elapsed;
  }

  /// Closes the underlying client if this instance created it.
  void close() {
    if (_ownsClient) _httpClient.close();
  }

  /// `<baseUrl>/api/<name>?<query>`, keeping any sub-path of [baseUrl] and
  /// dropping its user info (sent as a header instead), query and fragment.
  Uri _endpoint(String name, [Map<String, String>? query]) => Uri(
    scheme: baseUrl.scheme,
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
    pathSegments: [
      for (final segment in baseUrl.pathSegments)
        if (segment.isNotEmpty) segment,
      'api',
      name,
    ],
    queryParameters: query,
  );

  Future<List<MozhiLanguage>> _getLanguages(
    String endpoint,
    String engine,
  ) async {
    final (url, json) = await _getJson(_endpoint(endpoint, {'engine': engine}));
    return [
      for (final item in _expectList(json, url))
        if (item is Map<String, dynamic>) MozhiLanguage.fromJson(item),
    ];
  }

  /// POSTs the form to `/api/translate` and parses either response shape.
  Future<(Uri, List<MozhiTranslation>)> _postTranslate({
    required String engine,
    required String from,
    required String to,
    required String text,
  }) async {
    final (url, response) = await _send(
      _endpoint('translate'),
      (url, abortTrigger) =>
          http.AbortableRequest('POST', url, abortTrigger: abortTrigger)
            ..followRedirects = false
            // Form-encodes as UTF-8, like `http.Client.post` with a map.
            ..bodyFields = {
              'engine': engine,
              'from': from,
              'to': to,
              'text': text,
            },
    );
    final json = _decodeJson(response, url);
    final translations = json is Map<String, dynamic>
        ? [MozhiTranslation.fromJson(json)]
        : [
            for (final item in _expectList(json, url))
              if (item is Map<String, dynamic>) MozhiTranslation.fromJson(item),
          ];
    return (url, translations);
  }

  /// GETs [uri] and decodes the JSON body; returns the URL that answered.
  Future<(Uri, Object?)> _getJson(Uri uri) async {
    final (url, response) = await _send(uri, _get);
    return (url, _decodeJson(response, url));
  }

  /// GET requests keep following redirects natively: `dart:io` and `fetch`
  /// both do so correctly for GET.
  static http.BaseRequest _get(Uri url, Future<void> abortTrigger) =>
      http.AbortableRequest('GET', url, abortTrigger: abortTrigger);

  /// Sends the request built by [build] for [uri], follows redirects that
  /// the platform left to us, and returns the final URL with its response.
  ///
  /// Everything runs under [timeout]; when it runs out the request is
  /// aborted (for clients that support [http.Abortable]) instead of being
  /// left running. Every failure, including non-2xx responses, becomes a
  /// [MozhiApiException] whose `uri` is the last URL requested.
  Future<(Uri, http.Response)> _send(Uri uri, _RequestBuilder build) async {
    final abort = Completer<void>();
    var url = uri;
    Future<http.Response> exchange() async {
      for (var redirects = 0; ; redirects++) {
        final request = build(url, abort.future);
        if (_authorization case final authorization?
            when _isSameOrigin(url, uri)) {
          request.headers['authorization'] = authorization;
        }
        final response = await http.Response.fromStream(
          await _httpClient.send(request),
        );
        final next = redirects < maxRedirects
            ? _redirectTarget(url, response)
            : null;
        if (next == null) return response;
        // A redirect that arrives after the deadline must not start a new
        // upload nobody waits for.
        if (abort.isCompleted) throw http.RequestAbortedException(next);
        url = next;
      }
    }

    final http.Response response;
    try {
      response = await exchange().timeout(
        timeout,
        onTimeout: () {
          abort.complete();
          throw TimeoutException(null, timeout);
        },
      );
    } on Exception catch (error, stackTrace) {
      // http.ClientException covers socket/TLS failures on every platform;
      // anything else a custom client throws is still a transport failure.
      final message = switch (error) {
        TimeoutException() => 'No response within ${timeout.inMilliseconds} ms',
        http.ClientException(:final message) when message.isNotEmpty => message,
        _ => error.toString(),
      };
      Error.throwWithStackTrace(
        MozhiApiException(message, uri: url),
        stackTrace,
      );
    }
    final status = response.statusCode;
    if (status < 200 || status > 299) {
      throw MozhiApiException(
        _errorMessage(response),
        statusCode: status,
        uri: url,
      );
    }
    return (url, response);
  }

  /// Where to re-send a request that got [response] from [url], or `null`
  /// when [response] is not a redirect that is safe to follow: unknown
  /// status, no usable `Location`, a scheme other than http(s), or a
  /// downgrade from `https` to `http`. Credentials in `Location` are
  /// dropped; only [baseUrl]'s are ever sent, as a header.
  static Uri? _redirectTarget(Uri url, http.Response response) {
    if (!_redirectStatuses.contains(response.statusCode)) return null;
    final location = response.headers['location']?.trim() ?? '';
    final reference = location.isEmpty ? null : Uri.tryParse(location);
    if (reference == null) return null;
    final target = url.resolveUri(reference).removeFragment();
    final allowed =
        target.isScheme('https') ||
        (target.isScheme('http') && url.isScheme('http'));
    if (!allowed) return null;
    return target.userInfo.isEmpty ? target : target.replace(userInfo: '');
  }

  static bool _isSameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  /// `Basic base64(user:password)` for percent-encoded [userInfo], which
  /// `dart:io` would otherwise send without decoding (and `fetch` rejects).
  static String? _basicAuthorization(String userInfo) {
    if (userInfo.isEmpty) return null;
    final colon = userInfo.indexOf(':');
    final credentials = colon < 0
        ? '${_decodeCredential(userInfo)}:'
        : '${_decodeCredential(userInfo.substring(0, colon))}:'
              '${_decodeCredential(userInfo.substring(colon + 1))}';
    return 'Basic ${base64Encode(utf8.encode(credentials))}';
  }

  static String _decodeCredential(String encoded) {
    try {
      return Uri.decodeComponent(encoded);
    } on FormatException {
      // Escapes that do not form UTF-8 (`%FF`): send them as typed.
      return encoded;
    }
  }

  static String _decodeBody(http.Response response) =>
      // JSON and Fiber's plain-text errors are UTF-8, but Fiber sends
      // `application/json` without a charset, so do not trust Response.body.
      utf8.decode(response.bodyBytes, allowMalformed: true);

  static Object? _decodeJson(http.Response response, Uri uri) {
    try {
      return jsonDecode(_decodeBody(response));
    } on FormatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        MozhiApiException('Invalid JSON response: ${error.message}', uri: uri),
        stackTrace,
      );
    }
  }

  static Map<String, dynamic> _expectObject(Object? json, Uri uri) =>
      switch (json) {
        final Map<String, dynamic> object => object,
        _ => throw MozhiApiException(
          'Unexpected response: expected a JSON object',
          uri: uri,
        ),
      };

  /// Go serialises an empty (nil) slice as `null`.
  static List<Object?> _expectList(Object? json, Uri uri) => switch (json) {
    final List<Object?> list => list,
    null => const [],
    _ => throw MozhiApiException(
      'Unexpected response: expected a JSON array',
      uri: uri,
    ),
  };

  /// The most useful description of a non-2xx [response]: the plain-text
  /// body Fiber sends, the message of a JSON error body, the target of a
  /// redirect that was not followed, or else the reason phrase.
  static String _errorMessage(http.Response response) {
    final status = response.statusCode;
    final reason = response.reasonPhrase?.trim() ?? '';
    final fallback = reason.isEmpty ? 'HTTP $status' : reason;
    final location = response.headers['location']?.trim() ?? '';
    if (status >= 300 && status < 400 && location.isNotEmpty) {
      return 'Redirected to $location';
    }
    final body = _decodeBody(response).trim();
    final contentType = response.headers['content-type'] ?? '';
    // Reverse proxies answer with HTML error pages; never show markup.
    if (body.isEmpty || body.startsWith('<') || contentType.contains('html')) {
      return fallback;
    }
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return body;
    }
    return _messageFromJson(json) ?? fallback;
  }

  /// Finds a message in `"text"`, `{"message": ...}`, `{"error": ...}` or
  /// `{"detail": ...}` bodies, including nested `{"error": {"message": ..}}`.
  static String? _messageFromJson(Object? json) {
    if (json is String) return json.trim().isEmpty ? null : json.trim();
    if (json is Map) {
      for (final key in const ['message', 'error', 'detail']) {
        if (_messageFromJson(json[key]) case final message?) return message;
      }
    }
    return null;
  }
}
