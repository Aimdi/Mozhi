import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/web_translate/core/charset.dart';
import 'package:translation_repository/translation_repository.dart'
    show AiProviderConfig;

/// Why a page could not be loaded.
enum WebPageError {
  /// Not an http(s) address.
  invalidUrl,

  /// DNS, TLS, connection or protocol failure.
  network,

  /// The server answered with a non-2xx status ([WebPageException.statusCode]).
  httpStatus,

  /// Not HTML or text ([WebPageException.contentType]), e.g. a PDF.
  unsupportedContent,

  /// No response within the timeout.
  timeout,

  /// Web builds only: the browser refused the request, almost always
  /// because the site does not allow cross-origin (CORS) requests.
  blockedByBrowser,

  /// More redirects than allowed.
  tooManyRedirects,

  /// A public page redirected to this device or the local network
  /// (`localhost`, a private IP address, a `.local` name, ...). Such
  /// redirects are refused so that a website cannot make the app fetch,
  /// and then send to a translation engine, pages of routers, NAS boxes
  /// or other LAN services. Typing a local address directly still works.
  blockedRedirect,

  /// The page has no readable text.
  noContent,
}

/// A failure to load a web page.
class WebPageException implements Exception {
  const new(
    this.error, {
    this.uri,
    this.statusCode,
    this.contentType,
    this.cause,
  });

  final WebPageError error;
  final Uri? uri;
  final int? statusCode;
  final String? contentType;

  /// The underlying exception, when there is one.
  final Object? cause;

  /// Shows [uri] without user info, query and fragment (they may carry
  /// tokens), so logs never contain them.
  @override
  String toString() {
    final uri = this.uri;
    final shown = uri == null
        ? null
        : Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: uri.path,
          );
    return 'WebPageException(${error.name}'
        '${statusCode == null ? '' : ', $statusCode'}'
        '${contentType == null ? '' : ', $contentType'}'
        '${shown == null ? '' : ', $shown'}'
        '${cause == null ? '' : ', $cause'})';
  }
}

/// A downloaded page.
class FetchedWebPage {
  const new({
    required this.url,
    required this.body,
    required this.charset,
    this.contentType,
    this.truncated = false,
    this.unsupportedCharset,
  });

  /// Final address after redirects.
  final Uri url;

  /// Decoded document.
  final String body;

  /// Media type (`text/html`, `text/plain`, ...), lower-case, when sent.
  final String? contentType;

  /// Encoding used to decode [body].
  final String charset;

  /// The page was larger than the size cap and only its start was read.
  final bool truncated;

  /// A declared encoding that is not supported (see `decodeHtmlBytes`).
  final String? unsupportedCharset;

  bool get isPlainText => contentType == 'text/plain';
}

/// Downloads web pages for the reader view with `package:http`.
///
/// * Sends a desktop browser `User-Agent` (except on the web, where
///   browsers do not allow it) so that sites serve their full layout.
/// * Follows up to [maxRedirects] redirects (manually, to know the final
///   address; on the web the browser follows them). A redirect from a
///   public address to this device or the local network is refused
///   ([WebPageError.blockedRedirect], see [isLocalNetworkHost]).
/// * Reads at most [maxBytes] of the body (larger pages are truncated).
/// * Decodes the body with [decodeHtmlBytes] (HTTP charset, `<meta>`
///   charset, UTF-8 / windows-1252 fallback).
/// * Gives up after [timeout] for the whole download.
///
/// Errors are reported as [WebPageException]s.
class WebPageFetcher {
  new({
    http.Client? client,
    bool? isWeb,
    this.timeout = const Duration(seconds: 25),
    this.maxBytes = defaultMaxBytes,
    this.maxRedirects = 5,
    this.userAgent = desktopUserAgent,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _isWeb = isWeb ?? kIsWeb;

  /// 2 MiB.
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  /// A current desktop Chrome on Windows.
  static const desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  final http.Client _client;
  final bool _ownsClient;
  final bool _isWeb;
  final Duration timeout;
  final int maxBytes;
  final int maxRedirects;
  final String userAgent;

  /// Whether this fetcher runs in a browser (cross-origin limits apply).
  bool get isWeb => _isWeb;

  /// Downloads [uri]. Completing [abortTrigger] cancels the download (the
  /// returned future then fails with a [WebPageException] of kind
  /// [WebPageError.network]).
  Future<FetchedWebPage> fetch(Uri uri, {Future<void>? abortTrigger}) async {
    if (!_isHttp(uri)) {
      throw WebPageException(WebPageError.invalidUrl, uri: uri);
    }
    final abort = Completer<void>();
    unawaited(
      abortTrigger?.then((_) {
        if (!abort.isCompleted) abort.complete();
      }),
    );
    try {
      return await _fetch(uri, abort.future).timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw WebPageException(WebPageError.timeout, uri: uri);
        },
      );
    } on WebPageException {
      rethrow;
    } on TimeoutException catch (error) {
      throw WebPageException(WebPageError.timeout, uri: uri, cause: error);
    } on Object catch (error) {
      throw WebPageException(
        _isWeb ? WebPageError.blockedByBrowser : WebPageError.network,
        uri: uri,
        cause: error,
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<FetchedWebPage> _fetch(Uri uri, Future<void> abort) async {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      final request = http.AbortableRequest('GET', current, abortTrigger: abort)
        ..followRedirects = _isWeb
        ..maxRedirects = maxRedirects
        ..headers.addAll(_headers);
      final response = await _client.send(request);
      final status = response.statusCode;

      final location = response.headers['location'];
      if (!_isWeb && _isRedirect(status) && location != null) {
        unawaited(_discard(response));
        if (redirects >= maxRedirects) {
          throw WebPageException(WebPageError.tooManyRedirects, uri: current);
        }
        final next = current.resolve(location.trim());
        if (!_isHttp(next)) {
          throw WebPageException(WebPageError.invalidUrl, uri: next);
        }
        if (!isLocalNetworkHost(uri.host) && isLocalNetworkHost(next.host)) {
          throw WebPageException(WebPageError.blockedRedirect, uri: next);
        }
        current = next;
        continue;
      }

      final url = response is http.BaseResponseWithUrl
          ? (response as http.BaseResponseWithUrl).url
          : current;
      if (status < 200 || status >= 300) {
        unawaited(_discard(response));
        throw WebPageException(
          WebPageError.httpStatus,
          uri: url,
          statusCode: status,
        );
      }

      final contentType = response.headers['content-type'];
      final mediaType = _mediaType(contentType);
      if (mediaType != null && !_supportedTypes.contains(mediaType)) {
        unawaited(_discard(response));
        throw WebPageException(
          WebPageError.unsupportedContent,
          uri: url,
          contentType: mediaType,
        );
      }

      final (bytes, truncated) = await _readCapped(response.stream);
      final decoded = decodeHtmlBytes(bytes, contentType: contentType);
      return FetchedWebPage(
        url: url,
        body: decoded.text,
        contentType: mediaType,
        charset: decoded.charset,
        truncated: truncated,
        unsupportedCharset: decoded.unsupportedCharset,
      );
    }
  }

  Map<String, String> get _headers => {
    // Browsers forbid setting the User-Agent from scripts, and other
    // non-safelisted headers would trigger a CORS preflight.
    if (!_isWeb) 'User-Agent': userAgent,
    'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
    if (!_isWeb) 'Accept-Language': 'en;q=0.8,*;q=0.5',
  };

  Future<(Uint8List, bool)> _readCapped(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in stream) {
      final room = maxBytes - builder.length;
      if (chunk.length > room) {
        if (room > 0) builder.add(chunk.sublist(0, room));
        truncated = true;
        break; // Cancels the subscription (closes the connection).
      }
      builder.add(chunk);
    }
    return (builder.takeBytes(), truncated);
  }

  static Future<void> _discard(http.StreamedResponse response) async {
    try {
      await response.stream.listen(null).cancel();
    } on Object {
      // Nothing to clean up.
    }
  }

  static String? _mediaType(String? contentType) {
    if (contentType == null) return null;
    final type = contentType.split(';').first.trim().toLowerCase();
    return type.isEmpty ? null : type;
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// Whether [host] (as in [Uri.host]) is this device or on a private
  /// network: everything `AiProviderConfig.isLocalHost` accepts, plus
  /// numeric shorthands such as `0x7f.1` or `2130706433` that resolvers
  /// turn into IPv4 addresses.
  @visibleForTesting
  static bool isLocalNetworkHost(String host) {
    if (AiProviderConfig.isLocalHost(host)) return true;
    // Canonical dotted quads were classified above (public).
    if (_canonicalIpv4.hasMatch(host)) return false;
    final labels = host.toLowerCase().split('.');
    return labels.every(_numericLabel.hasMatch);
  }

  static final _canonicalIpv4 = RegExp(
    r'^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}'
    r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
  );
  static final _numericLabel = RegExp(r'^(?:0x[0-9a-f]*|[0-9]+)$');

  static bool _isHttp(Uri uri) =>
      (uri.isScheme('http') || uri.isScheme('https')) && uri.host.isNotEmpty;

  static const _supportedTypes = {
    'text/html',
    'application/xhtml+xml',
    'text/plain',
    'application/xml',
    'text/xml',
  };

  /// Closes the HTTP client when this fetcher created it.
  void close() {
    if (_ownsClient) _client.close();
  }
}
