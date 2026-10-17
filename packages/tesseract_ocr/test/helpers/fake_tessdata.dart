import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

/// Fake language data: [bytes] random-ish content with a catalog entry
/// pointing at `https://example.org/<code>.traineddata`.
class FakeTessdata {
  new(this.code, {int size = 4500, List<String>? languages, int seed = 1})
    : bytes = Uint8List.fromList(
        List.generate(size, (i) => (i * 31 + seed * 7 + i ~/ 97) & 0xFF),
      ),
      _languages = languages ?? [code.substring(0, 2)];

  final String code;
  final Uint8List bytes;
  final List<String> _languages;

  late final TessdataLanguage language = TessdataLanguage(
    code: code,
    name: code.toUpperCase(),
    languages: _languages,
    url: Uri.parse('https://example.org/$code.traineddata'),
    size: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}

/// A catalog of [data].
TessdataCatalog fakeCatalog(Iterable<FakeTessdata> data) =>
    TessdataCatalog([for (final item in data) item.language]);

/// Serves [FakeTessdata] files like raw.githubusercontent.com, with Range
/// support, failures and simulated disconnects.
class FakeTessdataServer {
  new(Iterable<FakeTessdata> data)
    : _files = {
        for (final item in data) item.language.url.toString(): item.bytes,
      };

  final Map<String, Uint8List> _files;
  final List<http.BaseRequest> requests = [];

  /// Per-URL replacement bodies (e.g. corrupted downloads).
  final Map<String, List<int>> overrides = {};

  /// URLs that answer with this status code.
  final Map<String, int> failures = {};

  /// When true, `Range` requests are answered with the whole file (200).
  bool ignoreRange = false;

  /// Stop a response after this many bytes (simulated disconnect).
  int? cutAfter;

  /// Throws on [http.Client.send] (no connection).
  bool offline = false;

  late final http.Client client = MockClient.streaming((request, _) async {
    requests.add(request);
    if (offline) throw const SocketException('Network is unreachable');
    final url = request.url.toString();
    final status = failures[url];
    if (status != null) {
      return http.StreamedResponse(Stream.value([1, 2, 3]), status);
    }
    final body = overrides[url] ?? _files[url];
    if (body == null) {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    final range = request.headers['Range'];
    var start = 0;
    var code = 200;
    if (range != null && !ignoreRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      code = 206;
    }
    final bytes = Uint8List.fromList(body.sublist(start));
    final cut = cutAfter;
    if (cut != null && cut < bytes.length) {
      cutAfter = null;
      return http.StreamedResponse(_thenFail(bytes.sublist(0, cut)), code);
    }
    return http.StreamedResponse(
      Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += 1000)
          bytes.sublist(i, min(i + 1000, bytes.length)),
      ]),
      code,
      contentLength: bytes.length,
    );
  });

  static Stream<List<int>> _thenFail(List<int> chunk) async* {
    yield chunk;
    throw const SocketException('Connection reset');
  }
}
