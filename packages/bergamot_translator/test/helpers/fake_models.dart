import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Contents of one fake model file, plus its catalog entry.
class FakeFile {
  new(this.kind, this.name, this.raw, Uri url)
    : gz = Uint8List.fromList(gzip.encode(raw)) {
    entry = CatalogFile(
      kind: kind,
      name: name,
      url: url,
      size: gz.length,
      sha256: sha256.convert(gz).toString(),
      uncompressedSize: raw.length,
      uncompressedSha256: sha256.convert(raw).toString(),
    );
  }

  final ModelFileKind kind;
  final String name;
  final Uint8List raw;
  final Uint8List gz;
  late final CatalogFile entry;
}

/// A fake model for [source] -> [target] with small random files.
class FakeModel {
  new(
    this.source,
    this.target, {
    this.version = 'run1',
    bool splitVocab = false,
    int seed = 1,
  }) {
    final random = Random(seed + source.hashCode + target.hashCode);
    Uint8List bytes(int length) => Uint8List.fromList([
      for (var i = 0; i < length; i++) random.nextInt(8) * 31,
    ]);
    final pair = '$source$target';
    Uri url(String name) =>
        Uri.parse('https://models.test/$source-$target/$version/$name.gz');
    files = [
      FakeFile(
        ModelFileKind.model,
        'model.$pair.intgemm.alphas.bin',
        bytes(3000),
        url('model.$pair.intgemm.alphas.bin'),
      ),
      FakeFile(
        ModelFileKind.lexicalShortlist,
        'lex.50.50.$pair.s2t.bin',
        bytes(1200),
        url('lex.50.50.$pair.s2t.bin'),
      ),
      if (splitVocab) ...[
        FakeFile(
          ModelFileKind.srcVocab,
          'srcvocab.$pair.spm',
          bytes(500),
          url('srcvocab.$pair.spm'),
        ),
        FakeFile(
          ModelFileKind.trgVocab,
          'trgvocab.$pair.spm',
          bytes(600),
          url('trgvocab.$pair.spm'),
        ),
      ] else
        FakeFile(
          ModelFileKind.vocab,
          'vocab.$pair.spm',
          bytes(800),
          url('vocab.$pair.spm'),
        ),
    ];
    catalog = CatalogModel(
      source: source,
      target: target,
      version: version,
      architecture: 'tiny',
      releaseStatus: 'Release',
      files: {for (final file in files) file.kind: file.entry},
    );
  }

  final String source;
  final String target;
  final String version;
  late final List<FakeFile> files;
  late final CatalogModel catalog;
}

/// Serves [FakeModel] files through a [MockClient], honouring `Range`.
class FakeModelServer {
  new(Iterable<FakeModel> models)
    : _files = {
        for (final model in models)
          for (final file in model.files) file.entry.url.toString(): file.gz,
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

  late final http.Client client = MockClient.streaming((request, _) async {
    requests.add(request);
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
    var bytes = body.sublist(start);
    final cut = cutAfter;
    if (cut != null && cut < bytes.length) {
      cutAfter = null;
      final partial = bytes.sublist(0, cut);
      return http.StreamedResponse(
        Stream.fromIterable([partial]).asyncExpand(
          (chunk) => Stream<List<int>>.fromIterable(
            [chunk],
          ).followedBy(Stream.error(const SocketException('Connection reset'))),
        ),
        code,
      );
    }
    bytes = Uint8List.fromList(bytes);
    return http.StreamedResponse(
      Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += 1000)
          bytes.sublist(i, min(i + 1000, bytes.length)),
      ]),
      code,
      contentLength: bytes.length,
    );
  });
}

extension on Stream<List<int>> {
  Stream<List<int>> followedBy(Stream<List<int>> next) async* {
    yield* this;
    yield* next;
  }
}

/// A catalog of [models].
ModelCatalog catalogOf(Iterable<FakeModel> models) =>
    ModelCatalog([for (final model in models) model.catalog]);
