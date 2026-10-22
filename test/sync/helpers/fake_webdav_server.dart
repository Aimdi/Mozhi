import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// How the fake server writes `PROPFIND` answers.
enum WebDavFlavor { nextcloud, apache, rclone }

/// An in-memory WebDAV server behind a [MockClient] ([client]): folders,
/// files with ETags, Basic authentication, `PROPFIND` (`Depth: 0`),
/// `MKCOL`, `GET` (`If-None-Match`), `PUT` (`If-Match`,
/// `If-None-Match: *`) and `DELETE`, answering like [flavor].
///
/// [intercept] answers a request instead of the server (return null to
/// let it through); [requests] lists every request.
class FakeWebDavServer {
  new({
    this.username = 'alice',
    this.password = 'app-password',
    this.flavor = WebDavFlavor.nextcloud,
    this.sendsEtags = true,
    this.honoursConditions = true,
    Set<String>? folders,
  }) : folders = folders ?? {'/dav/'};

  final String username;
  final String password;
  final WebDavFlavor flavor;

  /// Whether `GET` and `PUT` answers carry an `ETag` header (`PROPFIND`
  /// always lists `getetag`).
  bool sendsEtags;

  /// Whether `If-Match` and `If-None-Match: *` are checked on `PUT`
  /// (rclone ignores them).
  bool honoursConditions;

  /// Existing folders, as paths ending in `/`.
  final Set<String> folders;
  final files = <String, Uint8List>{};
  final _etags = <String, String>{};
  var _version = 0;
  final requests = <http.Request>[];
  FutureOr<http.Response?> Function(http.Request request)? intercept;

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    return await intercept?.call(request) ?? _handle(request);
  });

  /// The ETag of the file at [path].
  String? etagOf(String path) => _etags[path];

  /// Stores [bytes] at [path] as if a client wrote it.
  void put(String path, List<int> bytes) {
    files[path] = Uint8List.fromList(bytes);
    _etags[path] = '"v${++_version}"';
  }

  /// Deletes the file at [path] as if a client did.
  void remove(String path) {
    files.remove(path);
    _etags.remove(path);
  }

  /// The methods of [requests], in order.
  List<String> get methods => [for (final r in requests) r.method];

  http.Response _handle(http.Request request) {
    final expected =
        'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    if (request.headers['Authorization'] != expected) {
      return http.Response('', 401, headers: {'www-authenticate': 'Basic'});
    }
    final path = request.url.path;
    switch (request.method) {
      case 'PROPFIND':
        if (folders.contains(path)) return _multistatus(path, folder: true);
        if (files.containsKey(path)) return _multistatus(path, folder: false);
        return http.Response('', 404);
      case 'MKCOL':
        if (folders.contains(path) || files.containsKey(path)) {
          return http.Response('', 405);
        }
        if (!folders.contains(_parent(path))) return http.Response('', 409);
        folders.add(path);
        return http.Response('', 201);
      case 'GET':
        final file = files[path];
        if (file == null) return http.Response('', 404);
        final etag = _etags[path]!;
        if (request.headers['If-None-Match'] == etag) {
          return http.Response('', 304);
        }
        return http.Response.bytes(
          file,
          200,
          headers: {if (sendsEtags) 'etag': etag},
        );
      case 'PUT':
        if (!folders.contains(_parent(path))) return http.Response('', 409);
        final current = _etags[path];
        if (honoursConditions) {
          final ifMatch = request.headers['If-Match'];
          if (ifMatch != null && ifMatch != current) {
            return http.Response('', 412);
          }
          if (request.headers['If-None-Match'] == '*' && current != null) {
            return http.Response('', 412);
          }
        }
        put(path, request.bodyBytes);
        return http.Response(
          '',
          current == null ? 201 : 204,
          headers: {if (sendsEtags) 'etag': _etags[path]!},
        );
      case 'DELETE':
        if (!files.containsKey(path)) return http.Response('', 404);
        remove(path);
        return http.Response('', 204);
    }
    return http.Response('', 405);
  }

  static String _parent(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return trimmed.substring(0, trimmed.lastIndexOf('/') + 1);
  }

  http.Response _multistatus(String path, {required bool folder}) {
    final etag = folder ? '"folder"' : _etags[path]!;
    final collection = folder ? '<d:collection/>' : '';
    final body = switch (flavor) {
      WebDavFlavor.nextcloud => [
        '<?xml version="1.0"?>',
        '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">',
        '<d:response><d:href>$path</d:href><d:propstat><d:prop>',
        '<d:resourcetype>$collection</d:resourcetype>',
        '<d:getetag>${etag.replaceAll('"', '&quot;')}</d:getetag>',
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>',
        '</d:response></d:multistatus>',
      ],
      WebDavFlavor.apache => [
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">\n',
        '<D:response xmlns:lp1="DAV:">\n<D:href>$path</D:href>\n',
        '<D:propstat>\n<D:prop>\n',
        '<lp1:resourcetype>${folder ? '<D:collection/>' : ''}',
        '</lp1:resourcetype>\n',
        '<lp1:getetag>$etag</lp1:getetag>\n</D:prop>\n',
        '<D:status>HTTP/1.1 200 OK</D:status>\n</D:propstat>\n',
        '</D:response>\n</D:multistatus>\n',
      ],
      WebDavFlavor.rclone => [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<D:multistatus xmlns:D="DAV:"><D:response>',
        '<D:href>$path</D:href><D:propstat><D:prop><D:resourcetype>',
        if (folder) '<D:collection xmlns:D="DAV:"/>',
        '</D:resourcetype>',
        if (!folder) '<D:getetag>$etag</D:getetag>',
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>',
        '</D:response></D:multistatus>',
      ],
    }.join();
    return http.Response(
      body,
      207,
      headers: {'content-type': 'application/xml; charset=utf-8'},
    );
  }
}
