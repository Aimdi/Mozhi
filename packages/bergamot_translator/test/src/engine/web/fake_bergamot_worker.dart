import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:crypto/crypto.dart';

/// An in-memory stand-in for `web/bergamot/worker.js`: the same protocol,
/// storage operations with real size, SHA-256 and gzip checks (an OPFS of
/// [files]), and an engine that answers like `mozhi_bergamot_translate_ex`
/// (each text upper-cased, through every model of the chain).
class FakeBergamotWorker implements BergamotWorkerChannel {
  /// The "OPFS": path -> bytes.
  final Map<String, Uint8List> files = {};

  /// Every request, in order.
  final List<(String, Map<String, Object?>)> requests = [];

  /// Errors to answer an op with (once each).
  final Map<String, BergamotWorkerException> failNext = {};

  /// Callbacks run once after an op succeeded.
  final Map<String, void Function()> after = {};

  /// Ops that wait for their completer before answering.
  final Map<String, Completer<void>> holds = {};

  /// The answer to `probe`.
  Map<String, Object?> probe = {
    'simd': true,
    'opfs': true,
    'syncAccess': true,
    'decompression': true,
    'digest': true,
    'segmenter': true,
    'engine': true,
    'secure': true,
    'persisted': false,
  };

  /// The answer to `identify` (both passes).
  Map<String, Object?> detection = {
    'language': 'de',
    'languages': [
      {'code': 'de', 'percent': 97, 'score': 1345},
      {'code': 'un', 'percent': 0, 'score': 0},
    ],
    'textBytes': 36,
    'reliable': true,
  };

  /// Keys of the models the engine has loaded, least recently used first.
  final List<String> loaded = [];
  int maxModels = 2;
  int? idleSeconds;
  int terminated = 0;

  final Map<String, int> _open = {};

  List<String> get ops => [for (final (op, _) in requests) op];

  /// Whether a model was installed (its manifest exists).
  bool hasManifest(String directory) =>
      files.containsKey('$directory/manifest.json');

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) async {
    requests.add((op, arguments));
    await Future<void>.delayed(Duration.zero);
    final hold = holds.remove(op);
    if (hold != null) await hold.future;
    final failure = failNext.remove(op);
    if (failure != null) throw failure;
    final result = _handle(op, arguments);
    after.remove(op)?.call();
    return result;
  }

  Object? _handle(String op, Map<String, Object?> arguments) {
    return switch (op) {
      'probe' => probe,
      'configure' => _configure(arguments),
      'translate' => _translate(arguments),
      'preload' => _load(arguments['chain']! as List<Object?>),
      'identify' => {'precise': detection, 'bestEffort': detection},
      'release' => _release(arguments['key']! as String),
      'trim' => null,
      'dispose' => _release(null),
      'list' => _list(),
      'downloadOpen' => _downloadOpen(arguments),
      'downloadWrite' => _downloadWrite(arguments),
      'downloadClose' => _close(arguments['path']! as String),
      'install' => _install(arguments),
      'commit' => _commit(arguments),
      'remove' => _remove(arguments['path']! as String),
      'cleanUp' => _cleanUp(),
      _ => throw BergamotWorkerException(
        BergamotWorkerErrorKind.protocol,
        'Unknown op $op',
      ),
    };
  }

  @override
  void terminate() => terminated++;

  Object? _release(String? key) {
    if (key == null) {
      loaded.clear();
    } else {
      loaded.remove(key);
    }
    return null;
  }

  Object? _close(String path) {
    _open.remove(path);
    return null;
  }

  Object? _configure(Map<String, Object?> arguments) {
    maxModels = arguments['maxModels']! as int;
    idleSeconds = arguments['idleSeconds'] as int?;
    return null;
  }

  Object? _load(List<Object?> chain) {
    for (final spec in chain) {
      final model = spec! as Map<String, Object?>;
      for (final kind in ['model', 'shortlist', 'sourceVocab']) {
        if (!files.containsKey(model[kind])) {
          throw BergamotWorkerException(
            BergamotWorkerErrorKind.missing,
            '${model[kind]} is not there',
          );
        }
      }
      final key = model['key']! as String;
      loaded
        ..remove(key)
        ..add(key);
      while (loaded.length > maxModels) {
        loaded.removeAt(0);
      }
    }
    return null;
  }

  String _translate(Map<String, Object?> arguments) {
    _load(arguments['chain']! as List<Object?>);
    final texts = (arguments['texts']! as List<Object?>).cast<String>();
    final details = arguments['details'] == true;
    return jsonEncode([
      for (final text in texts)
        {
          'text': text.toUpperCase(),
          if (details)
            'sentences': [
              {
                'source': [0, text.length],
                'target': [0, text.length],
                'score': -0.1,
                'words': [
                  {
                    'target': [0, text.length],
                    'score': -0.1,
                    'source': [0, text.length],
                    'p': 0.9,
                  },
                ],
              },
            ],
        },
    ]);
  }

  List<Object?> _list() => [
    for (final path in files.keys)
      if (path.endsWith('/manifest.json') && path.startsWith('models/'))
        _entry(path.substring(0, path.length - '/manifest.json'.length)),
  ];

  Map<String, Object?> _entry(String directory) {
    final manifest = jsonDecode(
      utf8.decode(files['$directory/manifest.json']!),
    ) as Map<String, Object?>;
    var size = 0;
    for (final file in (manifest['files']! as Map<String, Object?>).values) {
      size += files['$directory/${(file! as Map)['name']}']?.length ?? 0;
    }
    return {'directory': directory, 'manifest': manifest, 'sizeBytes': size};
  }

  Map<String, Object?> _downloadOpen(Map<String, Object?> arguments) {
    final path = arguments['path']! as String;
    if (arguments['restart'] == true || !files.containsKey(path)) {
      files[path] = Uint8List(0);
    }
    _open[path] = files[path]!.length;
    return {'size': files[path]!.length};
  }

  Map<String, Object?> _downloadWrite(Map<String, Object?> arguments) {
    final path = arguments['path']! as String;
    if (!_open.containsKey(path)) {
      throw BergamotWorkerException(
        BergamotWorkerErrorKind.protocol,
        '$path is not open',
      );
    }
    final at = arguments['at']! as int;
    final bytes = arguments['bytes']! as Uint8List;
    final current = files[path]!;
    final next = Uint8List(at + bytes.length)
      ..setRange(0, at, current)
      ..setRange(at, at + bytes.length, bytes);
    files[path] = next;
    return {'size': next.length};
  }

  Map<String, Object?> _install(Map<String, Object?> arguments) {
    final part = arguments['part']! as String;
    _open.remove(part);
    final compressed = files[part];
    if (compressed == null) {
      throw BergamotWorkerException(
        BergamotWorkerErrorKind.missing,
        '$part is not there',
      );
    }
    if (compressed.length != arguments['size'] ||
        '${sha256.convert(compressed)}' != arguments['sha256']) {
      files.remove(part);
      throw BergamotWorkerException(
        BergamotWorkerErrorKind.checksum,
        '$part: checksum mismatch',
      );
    }
    final bytes = Uint8List.fromList(gzip.decode(compressed));
    if (bytes.length != arguments['uncompressedSize'] ||
        '${sha256.convert(bytes)}' != arguments['uncompressedSha256']) {
      files.remove(part);
      throw BergamotWorkerException(
        BergamotWorkerErrorKind.checksum,
        '${arguments['target']}: checksum mismatch',
      );
    }
    files
      ..[arguments['target']! as String] = bytes
      ..remove(part);
    return {'size': bytes.length};
  }

  Object? _commit(Map<String, Object?> arguments) {
    final directory = arguments['directory']! as String;
    files['$directory/manifest.json'] = utf8.encode(
      jsonEncode(arguments['manifest']),
    );
    final pair = directory.substring(0, directory.lastIndexOf('/'));
    files.removeWhere(
      (path, _) => path.startsWith('$pair/') && !path.startsWith('$directory/'),
    );
    if (arguments['downloads'] case final String downloads) {
      _remove(downloads);
    }
    return null;
  }

  Object? _remove(String path) {
    files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    _open.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    return null;
  }

  Object? _cleanUp() {
    final directories = {
      for (final path in files.keys)
        if (path.startsWith('models/') && path.split('/').length == 4)
          path.substring(0, path.lastIndexOf('/')),
    };
    for (final directory in directories) {
      if (!hasManifest(directory)) _remove(directory);
    }
    return null;
  }
}
