import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/sync/data/webdav_xml.dart';

/// Why a WebDAV request failed, in the terms the sync screen explains.
enum WebDavFailure {
  /// 401: wrong user name or (app) password.
  authFailed,

  /// 403: the account may not read or write there.
  forbidden,

  /// 404 or 409: the server address (or the folder's parent) does not
  /// exist on the server.
  notFound,

  /// The folder's address is a file.
  notAFolder,

  /// The server does not speak WebDAV there (`PROPFIND` refused, or a web
  /// page instead of a `207 Multi-Status`).
  notWebDav,

  /// 412: the file changed on the server since it was read (another
  /// device synced in between).
  conflict,

  /// 423: the file is locked on the server.
  locked,

  /// 507: the account's storage is full.
  insufficientStorage,

  /// 413, or an answer larger than [WebDavClient.maxDownloadBytes].
  tooLarge,

  /// 429: the server refuses requests for a while (for example
  /// Nextcloud's protection against password guessing).
  tooManyRequests,

  /// A redirect (3xx): the address is not the WebDAV address itself.
  redirected,

  /// Any other answer (5xx, unexpected statuses).
  server,

  /// No connection to the server.
  offline,

  /// The server took too long.
  timeout,

  /// The secure connection failed (certificate, TLS).
  tls,

  /// In the web app: `fetch` failed, which is what a browser reports for
  /// a server that is unreachable and for one that does not allow
  /// requests from the app's origin (CORS) alike.
  blockedByBrowser,

  /// Refused by the network policy before anything was sent (plain http
  /// to a public server, a `.onion` address without a proxy): see
  /// `describeNetworkPolicyError` with [WebDavException.cause].
  policy,
}

/// A failed WebDAV request. Its [toString] never holds an address or a
/// credential.
class WebDavException implements Exception {
  const new(this.failure, {this.statusCode, this.cause});

  final WebDavFailure failure;

  /// The HTTP status, when the server answered.
  final int? statusCode;

  /// The error behind a failure without an answer (for
  /// [WebDavFailure.policy]: the policy's exception).
  final Object? cause;

  @override
  String toString() =>
      'WebDavException(${failure.name}'
      '${statusCode == null ? '' : ', $statusCode'})';
}

/// What [WebDavClient.download] found.
sealed class WebDavDownload {
  const new();
}

/// The file does not exist (404).
final class WebDavMissing extends WebDavDownload {
  const new();
}

/// The file still has the ETag given as `If-None-Match` (304).
final class WebDavUnchanged extends WebDavDownload {
  const new();
}

/// The file's content and its ETag (null when the server sent none, or
/// a browser hid it: CORS without `Access-Control-Expose-Headers: ETag`).
final class WebDavFile extends WebDavDownload {
  const new(this.bytes, {this.etag});

  final Uint8List bytes;
  final String? etag;
}

/// A minimal WebDAV client for one folder ([folder]: [folderPath] below
/// [server]) and the files in it, with Basic authentication: what sync
/// needs and nothing more (`PROPFIND` with `Depth: 0`, `MKCOL`, `GET` with
/// `If-None-Match`, `PUT` with `If-Match` or `If-None-Match: *`,
/// `DELETE`).
///
/// Requests go through the given `httpClient` (sync passes the session's
/// client,
/// marked as sync for the network activity), so the network policy
/// applies: plain `http` only to this device, the local network and
/// `.onion`/`.i2p`. Redirects are never followed (the credentials would go
/// along): they fail as [WebDavFailure.redirected]. Every failure is a
/// [WebDavException].
class WebDavClient {
  new({
    required this.server,
    required this.username,
    required this._password,
    required http.Client httpClient,
    this.folderPath = '',
    this.timeout = defaultTimeout,
  }) : _client = httpClient,
       folder = folderUrl(server, folderPath);

  /// How long one request may take.
  static const defaultTimeout = Duration(seconds: 60);

  /// The largest answer read; a larger one fails as
  /// [WebDavFailure.tooLarge].
  static const int maxDownloadBytes = 64 * 1024 * 1024;

  /// The WebDAV address the user gave (Nextcloud:
  /// `https://cloud.example.org/remote.php/dav/files/alice/`).
  final Uri server;

  /// The folder below [server] (`Mozhi`, `Apps/Mozhi`; empty: [server]
  /// itself).
  final String folderPath;

  /// The ETag a browser's `GET` names to bypass its cache (see
  /// [download]).
  static const noCacheEtag = '"mozhi-no-cache"';

  /// The folder's URL (see [folderUrl]).
  final Uri folder;
  final String username;
  final Duration timeout;
  final String _password;
  final http.Client _client;

  /// This client for another [server] (same account and folder).
  WebDavClient withServer(Uri server) => WebDavClient(
    server: server,
    username: username,
    password: _password,
    httpClient: _client,
    folderPath: folderPath,
    timeout: timeout,
  );

  /// The URL of [folderPath] below [server], ending in `/`; [server]'s
  /// user info, query and fragment are dropped.
  static Uri folderUrl(Uri server, String folderPath) {
    final segments = [
      ...server.pathSegments.where((segment) => segment.isNotEmpty),
      ...folderSegments(folderPath),
    ];
    return Uri(
      scheme: server.scheme,
      host: server.host,
      port: server.hasPort ? server.port : null,
      pathSegments: segments.isEmpty ? null : [...segments, ''],
      path: segments.isEmpty ? '/' : null,
    );
  }

  /// The segments of [folderPath], without empty ones (`/Apps//Mozhi/` →
  /// `[Apps, Mozhi]`).
  static List<String> folderSegments(String folderPath) => [
    for (final segment in folderPath.split('/'))
      if (segment.trim().isNotEmpty) segment.trim(),
  ];

  /// The URL of the file [name] in [folder].
  Uri fileUrl(String name) => folder.replace(
    pathSegments: [
      ...folder.pathSegments.where((segment) => segment.isNotEmpty),
      name,
    ],
  );

  static const _propfindBody = '''
<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop>
</d:propfind>
''';

  /// The properties of [url] (`PROPFIND`, `Depth: 0`), or null when it
  /// does not exist.
  Future<DavResource?> stat(Uri url) async {
    final response = await _send(
      'PROPFIND',
      url,
      headers: const {
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: utf8.encode(_propfindBody),
    );
    final status = response.statusCode;
    if (status == 404 || status == 410) return null;
    // Web servers without WebDAV refuse the method or answer with a page.
    if (status == 400 ||
        status == 405 ||
        status == 501 ||
        (status >= 200 && status < 300 && status != 207)) {
      throw WebDavException(WebDavFailure.notWebDav, statusCode: status);
    }
    if (status != 207) throw _failureOf(status);
    final List<DavResource> resources;
    try {
      resources = parseMultistatus(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const WebDavException(WebDavFailure.notWebDav, statusCode: 207);
    }
    final resource = resources.firstOrNull;
    if (resource == null) {
      throw const WebDavException(WebDavFailure.notWebDav, statusCode: 207);
    }
    if (resource.status case final code? when code == 404 || code == 410) {
      return null;
    }
    return resource;
  }

  /// Makes sure [folder] exists: creates it (and the folders above it, up
  /// to [server], which must exist) when it does not. Throws
  /// [WebDavFailure.notAFolder] when it is a file.
  Future<void> ensureFolder() async {
    final existing = await stat(folder);
    if (existing != null) {
      // A server that lists no resourcetype at all is given the benefit of
      // the doubt when the href ends in a slash.
      final folderLike =
          existing.isCollection ||
          (!existing.hasResourceType && existing.href.endsWith('/'));
      if (!folderLike) {
        throw const WebDavException(WebDavFailure.notAFolder);
      }
      return;
    }
    bool named(String segment) => segment.isNotEmpty;
    final base = server.pathSegments.where(named).length;
    final target = folder.pathSegments.where(named).toList();
    if (target.length <= base) {
      // The server address itself is missing: nothing to create.
      throw const WebDavException(WebDavFailure.notFound, statusCode: 404);
    }
    // Each folder from the top (`Apps/`, then `Apps/Mozhi/`).
    for (var end = base + 1; end <= target.length; end++) {
      final url = folder.replace(pathSegments: [...target.take(end), '']);
      final status = (await _send('MKCOL', url)).statusCode;
      // 405: it exists already.
      if (status == 405 || (status >= 200 && status < 300)) continue;
      throw _failureOf(status);
    }
  }

  /// The file [name] in [folder] (`GET`); with [ifNoneMatch] (its last
  /// known ETag) [WebDavUnchanged] when it still has it.
  ///
  /// In a browser, a `GET` without [ifNoneMatch] still sends one (an ETag
  /// no file has): a request with a condition skips the browser's cache
  /// (Fetch standard, "HTTP-network-or-cache fetch"), which could otherwise
  /// answer with an older copy of the file.
  Future<WebDavDownload> download(String name, {String? ifNoneMatch}) async {
    final condition = ifNoneMatch ?? (kIsWeb ? noCacheEtag : null);
    final response = await _send(
      'GET',
      fileUrl(name),
      headers: {'If-None-Match': ?condition},
    );
    final status = response.statusCode;
    if (status == 404 || status == 410) return const WebDavMissing();
    if (status == 304) return const WebDavUnchanged();
    if (status != 200) throw _failureOf(status);
    return WebDavFile(response.bodyBytes, etag: _etagOf(response));
  }

  /// The ETag of the file [name] from `PROPFIND` (readable when a browser
  /// hides the `ETag` header), or null when it has none or is missing.
  Future<String?> etagOf(String name) async =>
      (await stat(fileUrl(name)))?.etag;

  /// Writes [bytes] as the file [name] (`PUT`): only if it still has the
  /// ETag [ifMatch], or, without one, only if it does not exist yet
  /// (`If-None-Match: *`); [unconditional] writes in any case (for
  /// servers that keep no ETags). Returns the new ETag when the server
  /// sent one. Throws [WebDavFailure.conflict] when the condition failed.
  Future<String?> upload(
    String name,
    Uint8List bytes, {
    String? ifMatch,
    bool unconditional = false,
  }) async {
    final response = await _send(
      'PUT',
      fileUrl(name),
      headers: {
        'Content-Type': 'application/octet-stream',
        if (ifMatch != null && !unconditional) 'If-Match': ifMatch,
        if (ifMatch == null && !unconditional) 'If-None-Match': '*',
      },
      body: bytes,
    );
    final status = response.statusCode;
    if (status < 200 || status > 299) throw _failureOf(status);
    return _etagOf(response);
  }

  /// Deletes the file [name] (`DELETE`); a file that is already gone is
  /// fine.
  Future<void> delete(String name) async {
    final response = await _send('DELETE', fileUrl(name));
    final status = response.statusCode;
    if (status == 404 || status == 410) return;
    if (status < 200 || status > 299) throw _failureOf(status);
  }

  static String? _etagOf(http.Response response) {
    final etag = response.headers['etag'] ?? response.headers['oc-etag'];
    final trimmed = etag?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<http.Response> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll(headers)
      ..headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$username:$_password'))}';
    if (body != null) request.bodyBytes = body;
    final http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request).timeout(timeout);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_failureOfError(error), stackTrace);
    }
    final status = streamed.statusCode;
    if (status >= 300 && status < 400 && status != 304) {
      unawaited(streamed.stream.drain<void>().catchError((Object _) {}));
      throw WebDavException(WebDavFailure.redirected, statusCode: status);
    }
    final Uint8List bytes;
    try {
      bytes = await _read(streamed.stream).timeout(timeout);
    } on WebDavException {
      rethrow;
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_failureOfError(error), stackTrace);
    }
    return http.Response.bytes(
      bytes,
      status,
      headers: streamed.headers,
      request: streamed.request,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  /// The bytes of [stream], at most [maxDownloadBytes].
  static Future<Uint8List> _read(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > maxDownloadBytes) {
        throw const WebDavException(WebDavFailure.tooLarge);
      }
    }
    return builder.takeBytes();
  }

  static WebDavException _failureOf(int status) =>
      WebDavException(switch (status) {
        401 => WebDavFailure.authFailed,
        403 => WebDavFailure.forbidden,
        404 || 409 || 410 => WebDavFailure.notFound,
        405 || 501 => WebDavFailure.notWebDav,
        412 => WebDavFailure.conflict,
        413 => WebDavFailure.tooLarge,
        423 => WebDavFailure.locked,
        429 => WebDavFailure.tooManyRequests,
        507 => WebDavFailure.insufficientStorage,
        >= 300 && < 400 => WebDavFailure.redirected,
        _ => WebDavFailure.server,
      }, statusCode: status);

  static WebDavException _failureOfError(Object error) {
    if (error is WebDavException) return error;
    if (error is TimeoutException) {
      return WebDavException(WebDavFailure.timeout, cause: error);
    }
    if (NetworkPolicyError.of(error) != null) {
      return WebDavException(WebDavFailure.policy, cause: error);
    }
    if (egressFailureOf(error) == EgressFailure.secureConnection) {
      return WebDavException(WebDavFailure.tls, cause: error);
    }
    return WebDavException(
      kIsWeb ? WebDavFailure.blockedByBrowser : WebDavFailure.offline,
      cause: error,
    );
  }
}
