import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// The size and SHA-256 of some bytes ([FileHashing]).
@immutable
final class FileDigest {
  const new({required this.size, required this.sha256});

  /// Bytes hashed (with a limit: at most one more than it, see
  /// [FileHashing.hashFile]).
  final int size;

  /// Lower-case hex SHA-256 of those bytes.
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is FileDigest && other.size == size && other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(size, sha256);

  @override
  String toString() => 'FileDigest($size, $sha256)';
}

/// Where the model manager hashes files: language data files are tens
/// of MB, and hashing them on the UI isolate would make it stutter.
///
/// [FileHashing.isolate] (the default) hashes and copies files in a
/// background isolate ([Isolate.run]) and hashes a download's bytes in a
/// long-lived one as they arrive ([stream]); [FileHashing.inline] does the
/// same work on the calling isolate (tests that cannot wait for isolates,
/// e.g. under a fake clock).
final class FileHashing {
  /// In background isolates.
  const new isolate() : _inline = false;

  /// On the calling isolate.
  const new inline() : _inline = true;

  final bool _inline;

  /// Bytes read at a time.
  static const int chunkSize = 1 << 20;

  /// The size and SHA-256 of the file at [path]. With [maxBytes] it stops
  /// after `maxBytes + 1` bytes (the file is too long then: its size says
  /// so). Throws a [FileSystemException] when it cannot be read.
  Future<FileDigest> hashFile(String path, {int? maxBytes}) =>
      _run(() => _hashFileSync(path, maxBytes));

  /// Copies the file at [from] to [to] (created or truncated) while
  /// hashing it; the digest of what was written. With [maxBytes] it stops
  /// after `maxBytes + 1` bytes. Throws a [FileSystemException] when one of
  /// them cannot be read or written.
  Future<FileDigest> copyFile(String from, String to, {int? maxBytes}) =>
      _run(() => _copyFileSync(from, to, maxBytes));

  /// A hasher fed with a download's bytes as they arrive (and the bytes of
  /// a partial download first, [StreamHasher.addFile]).
  Future<StreamHasher> stream() async =>
      _inline ? _InlineStreamHasher() : await _IsolateStreamHasher.start();

  Future<T> _run<T>(T Function() work) async =>
      _inline ? work() : await Isolate.run(work, debugName: 'model hashing');
}

/// Hashes bytes chunk by chunk ([FileHashing.stream]).
abstract interface class StreamHasher {
  /// Hashes the bytes of the file at [path] first (a resumed download's
  /// part, before what is appended to it); its length. Throws a
  /// [FileSystemException] when it cannot be read.
  Future<int> addFile(String path);

  /// Hashes [chunk]. The future completes at once, unless the hashing
  /// falls far behind (then once it caught up).
  Future<void> add(List<int> chunk);

  /// The size and SHA-256 of everything added. Ends the hasher.
  Future<FileDigest> close();

  /// Stops the hasher without a result (an interrupted download). Does
  /// nothing after [close].
  void abort();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// SHA-256 fed chunk by chunk, counting the bytes.
final class _Sha256 {
  final _sink = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_sink);
  int size = 0;

  void add(List<int> chunk) {
    size += chunk.length;
    _input.add(chunk);
  }

  FileDigest close() {
    _input.close();
    return FileDigest(size: size, sha256: _sink.value.toString());
  }
}

/// Reads [file] in chunks into [onChunk] until it ends or more than
/// [maxBytes] were read.
void _readSync(
  RandomAccessFile file,
  int? maxBytes,
  void Function(Uint8List chunk) onChunk,
) {
  final buffer = Uint8List(FileHashing.chunkSize);
  var total = 0;
  for (;;) {
    final read = file.readIntoSync(buffer);
    if (read <= 0) return;
    total += read;
    onChunk(Uint8List.sublistView(buffer, 0, read));
    if (maxBytes != null && total > maxBytes) return;
  }
}

FileDigest _hashFileSync(String path, int? maxBytes) {
  final hash = _Sha256();
  final file = File(path).openSync();
  try {
    _readSync(file, maxBytes, hash.add);
  } finally {
    file.closeSync();
  }
  return hash.close();
}

FileDigest _copyFileSync(String from, String to, int? maxBytes) {
  final hash = _Sha256();
  final input = File(from).openSync();
  try {
    final output = File(to).openSync(mode: FileMode.writeOnly);
    try {
      _readSync(input, maxBytes, (chunk) {
        hash.add(chunk);
        output.writeFromSync(chunk);
      });
      output.flushSync();
    } finally {
      output.closeSync();
    }
  } finally {
    input.closeSync();
  }
  return hash.close();
}

final class _InlineStreamHasher implements StreamHasher {
  final _hash = _Sha256();

  @override
  Future<int> addFile(String path) async {
    final before = _hash.size;
    await File(path).openRead().forEach(_hash.add);
    return _hash.size - before;
  }

  @override
  Future<void> add(List<int> chunk) {
    _hash.add(chunk);
    return Future.value();
  }

  @override
  Future<FileDigest> close() async => _hash.close();

  @override
  void abort() {}
}

/// [StreamHasher] in a background isolate: chunks are sent to it as they
/// arrive (a copy each), and at most [_maxPending] bytes wait there before
/// [add] holds the download back.
final class _IsolateStreamHasher implements StreamHasher {
  new _(this._isolate, this._requests, this._responses) {
    _subscription = _responses.listen(_handle);
  }

  static const int _maxPending = 32 << 20;

  static Future<_IsolateStreamHasher> start() async {
    final responses = ReceivePort('model hashing');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        responses.sendPort,
        debugName: 'model hashing',
        onError: responses.sendPort,
        onExit: responses.sendPort,
      );
      // An isolate that cannot start (out of memory): the download fails
      // with this error.
      // coverage:ignore-start
    } on Object {
      responses.close();
      rethrow;
    }
    // coverage:ignore-end
    final stream = responses.asBroadcastStream();
    final first = await stream.first;
    // coverage:ignore-start
    if (first is! SendPort) {
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      throw StateError('The hashing isolate did not start: $first');
    }
    // coverage:ignore-end
    return _IsolateStreamHasher._(isolate, first, stream);
  }

  final Isolate _isolate;
  final SendPort _requests;
  final Stream<Object?> _responses;
  late final StreamSubscription<Object?> _subscription;
  Completer<Object?>? _waiting;
  int _pending = 0;
  Completer<void>? _caughtUp;
  bool _done = false;
  Object? _failure;

  void _handle(Object? message) {
    switch (message) {
      case final int acknowledged:
        _pending -= acknowledged;
        if (_pending <= _maxPending ~/ 2) {
          _caughtUp?.complete();
          _caughtUp = null;
        }
      case final _Result result:
        final waiting = _waiting;
        _waiting = null;
        waiting?.complete(result.value);
      // The isolate died ([message] is its error or the exit message): a
      // crash of the hashing code, which nothing here provokes.
      // coverage:ignore-start
      default:
        _fail(StateError('The hashing isolate stopped: $message'));
    }
  }

  void _fail(Object error) {
    _failure ??= error;
    _waiting?.completeError(error);
    _waiting = null;
    _caughtUp?.completeError(error);
    _caughtUp = null;
    abort();
  }
  // coverage:ignore-end

  Future<Object?> _ask(Object request) {
    if (_failure case final failure?) return Future.error(failure);
    if (_done) return Future.error(StateError('The hasher is closed'));
    final waiting = _waiting = Completer<Object?>();
    _requests.send(request);
    return waiting.future;
  }

  @override
  Future<int> addFile(String path) async {
    final answer = await _ask(_AddFile(path));
    if (answer is FileSystemException) throw answer;
    return answer! as int;
  }

  @override
  Future<void> add(List<int> chunk) {
    if (_failure case final failure?) return Future.error(failure);
    if (_done) return Future.error(StateError('The hasher is closed'));
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _pending += bytes.length;
    _requests.send(bytes);
    if (_pending <= _maxPending) return Future.value();
    return (_caughtUp ??= Completer<void>()).future;
  }

  @override
  Future<FileDigest> close() async {
    try {
      return (await _ask(const _Close()))! as FileDigest;
    } finally {
      abort();
    }
  }

  @override
  void abort() {
    if (_done) return;
    _done = true;
    unawaited(_subscription.cancel());
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _main(SendPort responses) {
    final requests = RawReceivePort();
    final hash = _Sha256();
    void handle(Object? message) {
      switch (message) {
        case final Uint8List chunk:
          hash.add(chunk);
          responses.send(chunk.length);
        case _AddFile(:final path):
          final before = hash.size;
          try {
            final file = File(path).openSync();
            try {
              _readSync(file, null, hash.add);
            } finally {
              file.closeSync();
            }
            responses.send(_Result(hash.size - before));
          } on FileSystemException catch (error) {
            responses.send(_Result(error));
          }
        case _Close():
          responses.send(_Result(hash.close()));
          requests.close();
      }
    }

    requests.handler = handle;
    responses.send(requests.sendPort);
  }
}

final class _AddFile {
  const new(this.path);

  final String path;
}

final class _Close {
  const new();
}

final class _Result {
  const new(this.value);

  final Object? value;
}
