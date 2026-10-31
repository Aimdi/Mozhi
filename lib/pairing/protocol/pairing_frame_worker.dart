import 'dart:async';
import 'dart:typed_data';

import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_codec.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker_web.dart'
    if (dart.library.io) 'package:mozhi/pairing/protocol/pairing_frame_worker_io.dart'
    as platform;

/// Runs a [PairingFrameCodec] away from the caller's work: on a background
/// isolate in the Android app (`pairing_frame_worker_io.dart`, with
/// compression), or on the caller's isolate with a pause before each frame
/// in a browser ([InlinePairingFrameWorker]), so that encrypting,
/// compressing and hashing a large transfer leaves the UI responsive.
///
/// The calls mirror the codec's. After [close], pending and later calls
/// fail with [PairingClosedException].
abstract interface class PairingFrameWorker {
  /// The worker of this platform for a connection's keys (each a 32-byte
  /// AES key); its isolate, if any, starts with the first call.
  static PairingFrameWorker start({
    required List<int> outgoing,
    required List<int> incoming,
  }) =>
      platform.startPairingFrameWorker(outgoing: outgoing, incoming: incoming);

  /// This platform's compression (null in a browser): what its workers
  /// use, and a channel for the small frames it handles itself.
  static PairingDeflate? get deflate => platform.pairingDeflate;

  /// Whether this platform inflates compressed file data (what a phone
  /// tells the other one in its `hello`).
  static bool get inflates => deflate != null;

  /// See [PairingFrameCodec.seal].
  Future<Uint8List> seal(int number, int type, Uint8List payload);

  /// See [PairingFrameCodec.sealData].
  Future<({Uint8List frame, int sent})> sealData(
    int number,
    Uint8List bytes, {
    required bool compress,
  });

  /// See [PairingFrameCodec.open].
  Future<(int, Uint8List)> open(int number, Uint8List sealed);

  /// See [PairingFrameCodec.startHash].
  Future<void> startHash({required bool sha256, required bool sha1});

  /// See [PairingFrameCodec.finishHash].
  Future<PairingDigests> finishHash();

  /// Stops the worker.
  void close();
}

/// A [PairingFrameWorker] on the caller's isolate: each call waits for
/// the event loop once (so input and frames get their turn between two
/// frames), then runs the codec.
class InlinePairingFrameWorker implements PairingFrameWorker {
  new(this._codec);

  final PairingFrameCodec _codec;
  bool _closed = false;

  @override
  Future<Uint8List> seal(int number, int type, Uint8List payload) =>
      _run(() => _codec.seal(number, type, payload));

  @override
  Future<({Uint8List frame, int sent})> sealData(
    int number,
    Uint8List bytes, {
    required bool compress,
  }) => _run(() => _codec.sealData(number, bytes, compress: compress));

  @override
  Future<(int, Uint8List)> open(int number, Uint8List sealed) =>
      _run(() => _codec.open(number, sealed));

  @override
  Future<void> startHash({required bool sha256, required bool sha1}) =>
      _run(() => _codec.startHash(sha256: sha256, sha1: sha1));

  @override
  Future<PairingDigests> finishHash() => _run(_codec.finishHash);

  @override
  void close() => _closed = true;

  Future<T> _run<T>(T Function() work) async {
    await Future<void>.delayed(Duration.zero);
    if (_closed) throw const PairingClosedException();
    return work();
  }
}
