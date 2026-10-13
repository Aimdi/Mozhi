import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mozhi_api/mozhi_api.dart' show MozhiApiException;
import 'package:mozhi_api/src/models/models.dart';
import 'package:mozhi_api/src/mozhi_api_exception.dart' show MozhiApiException;

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
class MozhiApiClient {
  new({
    required this.baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Root of the instance, e.g. `https://mozhi.aryak.me` or
  /// `http://192.168.1.10:3000/mozhi` (sub-path deployments are allowed).
  final Uri baseUrl;
  final Duration timeout;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// Turns user input into a canonical base URL:
  /// trims whitespace, adds `https://` when no scheme is given (but `http://`
  /// for `localhost`, `127.*`, `10.*`, `192.168.*`, `172.16-31.*` and
  /// `*.local` hosts), drops query/fragment, strips a trailing `/` and a
  /// trailing `/api` segment.
  /// Throws [FormatException] when the input cannot be a URL.
  static Uri normalizeBaseUrl(String input) {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// `GET /api/engines`. Returns engine id -> display name, *excluding* the
  /// `all` and `some` pseudo-engines, sorted by display name.
  Future<Map<String, String>> getEngines() {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// `GET /api/source_languages?engine=<engine>`.
  Future<List<MozhiLanguage>> getSourceLanguages(String engine) {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// `GET /api/target_languages?engine=<engine>`.
  Future<List<MozhiLanguage>> getTargetLanguages(String engine) {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// Translates [text] with a single [engine] (POST form).
  Future<MozhiTranslation> translate({
    required String engine,
    required String from,
    required String to,
    required String text,
  }) {
    throw UnimplementedError('TODO(mozhi_api)');
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
  }) {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// `GET /api/tts`. Only `google` and `reverso` support TTS. Returns the
  /// MP3 bytes. Throws [MozhiApiException] when the body is empty.
  Future<Uint8List> textToSpeech({
    required String engine,
    required String language,
    required String text,
  }) {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// `POST /api/image` (multipart). [pngBytes] must be a PNG image; only the
  /// Google engine is implemented server-side.
  Future<MozhiImageTranslation> translateImage({
    required Uint8List pngBytes,
    required String from,
    required String to,
    String engine = 'google',
  }) {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// `GET /api/version`. Cheap; used as a health check.
  Future<MozhiVersion> getVersion() {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// Measures round-trip latency of [getVersion]. Throws on failure.
  Future<Duration> ping() {
    throw UnimplementedError('TODO(mozhi_api)');
  }

  /// Closes the underlying client if this instance created it.
  void close() {
    if (_ownsClient) _httpClient.close();
  }
}
