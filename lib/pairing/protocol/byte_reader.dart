import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:mozhi/pairing/protocol/pairing_exception.dart';

/// Reads exact numbers of bytes from a byte stream (a socket), each read
/// with a timeout. Holds at most about [maxBuffered] bytes the reader has
/// not asked for yet: beyond that the stream is paused, so a fast sender
/// waits instead of filling the memory.
///
/// A closed stream fails reads with [PairingClosedException] (after the
/// bytes that arrived before), a stream error with
/// [PairingClosedException] too, and a read that does not complete in
/// time with [PairingTimeoutException]. One read at a time.
class PairingByteReader {
  new(Stream<List<int>> source, {this.maxBuffered = 1 << 20}) {
    _subscription = source.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  /// Bytes buffered before the stream is paused.
  final int maxBuffered;

  late final StreamSubscription<List<int>> _subscription;
  final Completer<void> _closed = Completer();
  final Queue<Uint8List> _chunks = Queue();
  int _buffered = 0;
  bool _done = false;
  Object? _error;
  _Read? _pending;

  /// Bytes received and not read yet.
  int get buffered => _buffered;

  /// Completes when the stream ends or fails, or at [cancel] (a socket
  /// whose other end went away: its writes may then never complete).
  Future<void> get closed => _closed.future;

  /// The next [length] bytes. Throws [StateError] while another read is
  /// pending.
  Future<Uint8List> read(int length, {required Duration timeout}) {
    if (_pending != null) throw StateError('A read is pending');
    if (length < 0) throw ArgumentError.value(length, 'length');
    if (_buffered >= length) return Future.value(_take(length));
    if (_error != null || _done) return Future.error(_failure);
    final read = _Read(length);
    _pending = read;
    read.timer = Timer(timeout, () {
      if (!identical(_pending, read)) return;
      _pending = null;
      read.completer.completeError(const PairingTimeoutException());
    });
    if (_subscription.isPaused) _subscription.resume();
    return read.completer.future;
  }

  /// Stops reading: a pending read fails with [PairingClosedException].
  Future<void> cancel() async {
    _done = true;
    _fail();
    _close();
    await _subscription.cancel();
  }

  PairingException get _failure => switch (_error) {
    null => const PairingClosedException(),
    final error => PairingClosedException('$error'),
  };

  void _onData(List<int> data) {
    if (data.isEmpty) return;
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    _chunks.add(chunk);
    _buffered += chunk.length;
    final read = _pending;
    if (read != null && _buffered >= read.length) {
      _pending = null;
      read.timer?.cancel();
      read.completer.complete(_take(read.length));
    }
    if (_buffered >= maxBuffered &&
        _pending == null &&
        !_subscription.isPaused) {
      _subscription.pause();
    }
  }

  void _onError(Object error) {
    _error = error;
    _fail();
    _close();
  }

  void _onDone() {
    _done = true;
    _fail();
    _close();
  }

  void _close() {
    if (!_closed.isCompleted) _closed.complete();
  }

  void _fail() {
    final read = _pending;
    if (read == null) return;
    _pending = null;
    read.timer?.cancel();
    read.completer.completeError(_failure);
  }

  Uint8List _take(int length) {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final chunk = _chunks.first;
      final needed = length - offset;
      if (chunk.length <= needed) {
        result.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
        _chunks.removeFirst();
      } else {
        result.setRange(offset, length, chunk);
        _chunks
          ..removeFirst()
          ..addFirst(Uint8List.sublistView(chunk, needed));
        offset = length;
      }
    }
    _buffered -= length;
    if (_buffered < maxBuffered && _subscription.isPaused) {
      _subscription.resume();
    }
    return result;
  }
}

class _Read {
  new(this.length);

  final int length;
  final Completer<Uint8List> completer = Completer();
  Timer? timer;
}
