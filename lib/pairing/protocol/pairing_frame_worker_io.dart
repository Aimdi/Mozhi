import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_codec.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker.dart';

/// In the app: the codec on a background isolate, with compression.
PairingFrameWorker startPairingFrameWorker({
  required List<int> outgoing,
  required List<int> incoming,
}) => IsolatePairingFrameWorker(outgoing: outgoing, incoming: incoming);

/// The app's compression.
PairingDeflate? get pairingDeflate => const ZLibPairingDeflate();

/// Raw deflate with `dart:io`'s zlib, at [level] (1, the fastest, by
/// default: most of what goes across is model weights, where a higher
/// level gains little and costs a lot of time).
class ZLibPairingDeflate implements PairingDeflate {
  const new({this.level = 1});

  final int level;

  @override
  Uint8List compress(Uint8List bytes) =>
      _bytes(ZLibEncoder(raw: true, level: level).convert(bytes));

  @override
  Uint8List inflate(Uint8List bytes, {required int limit}) {
    final output = _LimitedSink(limit);
    try {
      ZLibDecoder(raw: true).startChunkedConversion(output)
        ..add(bytes)
        ..close();
    } on _TooLong {
      throw const PairingProtocolException('Data inflates beyond a frame');
    } on Object {
      throw const PairingProtocolException('Data does not inflate');
    }
    return output.takeBytes();
  }

  static Uint8List _bytes(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

/// Collects inflated bytes and throws [_TooLong] past its limit, which
/// stops the inflater (it hands its output over piece by piece).
class _LimitedSink implements Sink<List<int>> {
  new(this.limit);

  final int limit;
  final _bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (_bytes.length + data.length > limit) throw const _TooLong();
    _bytes.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

class _TooLong implements Exception {
  const new();
}

/// A [PairingFrameWorker] on an isolate of its own, started with the first
/// call and killed by [close]. The calls are answered in order.
class IsolatePairingFrameWorker implements PairingFrameWorker {
  new({
    required List<int> outgoing,
    required List<int> incoming,
    this.deflate = const ZLibPairingDeflate(),
  }) : _outgoing = Uint8List.fromList(outgoing),
       _incoming = Uint8List.fromList(incoming);

  /// The worker's compression.
  final PairingDeflate deflate;

  final Uint8List _outgoing;
  final Uint8List _incoming;
  final Map<int, Completer<Object?>> _calls = {};
  Future<SendPort>? _port;
  Completer<SendPort>? _ready;
  RawReceivePort? _replies;
  Isolate? _isolate;
  int _next = 0;
  bool _closed = false;

  @override
  Future<Uint8List> seal(int number, int type, Uint8List payload) async =>
      (await _call(_Seal(number, type, payload)))! as Uint8List;

  @override
  Future<({Uint8List frame, int sent})> sealData(
    int number,
    Uint8List bytes, {
    required bool compress,
  }) async =>
      (await _call(_SealData(number, bytes, compress: compress)))!
          as ({Uint8List frame, int sent});

  @override
  Future<(int, Uint8List)> open(int number, Uint8List sealed) async =>
      (await _call(_Open(number, sealed)))! as (int, Uint8List);

  @override
  Future<void> startHash({required bool sha256, required bool sha1}) =>
      _call(_StartHash(sha256: sha256, sha1: sha1));

  @override
  Future<PairingDigests> finishHash() async =>
      (await _call(const _FinishHash()))! as PairingDigests;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _replies?.close();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const PairingClosedException());
    }
    _failAll(const PairingClosedException());
  }

  Future<Object?> _call(_Request request) async {
    if (_closed) throw const PairingClosedException();
    final port = await (_port ??= _spawn());
    if (_closed) throw const PairingClosedException();
    final id = _next++;
    final reply = Completer<Object?>();
    _calls[id] = reply;
    port.send((id, request));
    final result = await reply.future;
    if (result is _Failure) throw result.exception;
    return result;
  }

  Future<SendPort> _spawn() async {
    final ready = _ready = Completer<SendPort>();
    // It may fail (a close) before it is awaited below.
    ready.future.ignore();
    late final RawReceivePort replies;
    replies = _replies = RawReceivePort((Object? message) {
      switch (message) {
        case final SendPort port:
          ready.complete(port);
        case (final int id, final Object? result):
          _calls.remove(id)?.complete(result);
        default:
          // The isolate failed (`[error, stack]`) or exited (null).
          final error = PairingClosedException('Worker stopped: $message');
          if (!ready.isCompleted) ready.completeError(error);
          _closed = true;
          replies.close();
          _failAll(error);
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _main,
        (replies.sendPort, _outgoing, _incoming, deflate),
        onError: replies.sendPort,
        onExit: replies.sendPort,
        debugName: 'pairing frames',
      );
      _isolate = isolate;
      if (_closed) isolate.kill(priority: Isolate.immediate);
    } on Object catch (error) {
      // coverage:ignore-start
      replies.close();
      throw PairingClosedException('$error');
      // coverage:ignore-end
    }
    return await ready.future;
  }

  void _failAll(PairingException error) {
    final calls = [..._calls.values];
    _calls.clear();
    for (final call in calls) {
      call.complete(_Failure(error));
    }
  }

  static void _main((SendPort, Uint8List, Uint8List, PairingDeflate) start) {
    final (replies, outgoing, incoming, deflate) = start;
    final codec = PairingFrameCodec(
      outgoing: outgoing,
      incoming: incoming,
      deflate: deflate,
    );
    final requests = RawReceivePort((Object? message) {
      final (id, request) = message! as (int, _Request);
      Object? result;
      try {
        result = request.run(codec);
      } on PairingException catch (error) {
        result = _Failure(error);
      } on Object catch (error) {
        result = _Failure(PairingProtocolException('$error'));
      }
      replies.send((id, result));
    });
    replies.send(requests.sendPort);
  }
}

/// A call of the worker, run on its isolate.
sealed class _Request {
  const new();

  Object? run(PairingFrameCodec codec);
}

final class _Seal extends _Request {
  const new(this.number, this.type, this.payload);

  final int number;
  final int type;
  final Uint8List payload;

  @override
  Object? run(PairingFrameCodec codec) => codec.seal(number, type, payload);
}

final class _SealData extends _Request {
  const new(this.number, this.bytes, {required this.compress});

  final int number;
  final Uint8List bytes;
  final bool compress;

  @override
  Object? run(PairingFrameCodec codec) =>
      codec.sealData(number, bytes, compress: compress);
}

final class _Open extends _Request {
  const new(this.number, this.sealed);

  final int number;
  final Uint8List sealed;

  @override
  Object? run(PairingFrameCodec codec) => codec.open(number, sealed);
}

final class _StartHash extends _Request {
  const new({required this.sha256, required this.sha1});

  final bool sha256;
  final bool sha1;

  @override
  Object? run(PairingFrameCodec codec) {
    codec.startHash(sha256: sha256, sha1: sha1);
    return null;
  }
}

final class _FinishHash extends _Request {
  const new();

  @override
  Object? run(PairingFrameCodec codec) => codec.finishHash();
}

/// A call that threw [exception].
final class _Failure {
  const new(this.exception);

  final PairingException exception;
}
