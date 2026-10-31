import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_codec.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker.dart';
import 'package:mozhi/pairing/protocol/pairing_handshake.dart';

export 'package:mozhi/pairing/protocol/pairing_frame_codec.dart'
    show PairingDigests, PairingFrameType;

/// One frame from the other phone.
sealed class PairingFrame {
  const new();
}

/// A control message: a JSON object whose `t` names its [type].
final class PairingMessage extends PairingFrame {
  const new(this.type, this.fields);

  final String type;

  /// The whole object, `t` included.
  final Map<String, Object?> fields;

  @override
  String toString() => 'PairingMessage($type)';
}

/// A piece of the file being sent.
final class PairingData extends PairingFrame {
  const new(this.bytes);

  final Uint8List bytes;

  @override
  String toString() => 'PairingData(${bytes.length})';
}

/// What a phone's `hello` can list besides the version (`features`).
abstract final class PairingFeature {
  /// It takes file data compressed with raw deflate
  /// ([PairingFrameType.compressedData]).
  static const deflate = 'deflate';
}

/// The encrypted frames of a pairing connection, after the
/// [PairingHandshake]:
///
/// * each frame is a 4-byte big-endian length, then that many bytes of
///   AES-256-GCM ciphertext and tag (one key per direction, the nonce the
///   frame's number in that direction, so a replayed, dropped or reordered
///   frame fails to decrypt like a changed one);
/// * the plaintext is a type byte and its payload ([PairingFrameType]): 1
///   for a message (a UTF-8 JSON object, see [PairingMessage]), 2 for
///   file data, 3 for file data compressed with raw deflate, which only
///   goes to a phone whose `hello` lists [PairingFeature.deflate]
///   ([sendFileData]; a phone of an earlier version lists nothing and
///   gets type 2);
/// * a payload holds at most [maxPayload] bytes, also once inflated: a
///   longer frame is refused before it is read.
///
/// File data and any frame larger than a few KiB are sealed, opened,
/// compressed and hashed by a [PairingFrameWorker] (a background isolate
/// in the app), so a large transfer doesn't load the UI isolate; small
/// frames are handled at once (a small compressed one is inflated at once
/// too, to at most [maxPayload]).
///
/// Anything that fails ends the channel: a frame that does not decrypt
/// ([PairingAuthenticationException]), a malformed or oversize one
/// ([PairingProtocolException]), a closed socket
/// ([PairingClosedException]) or a read that times out
/// ([PairingTimeoutException]). A `cancel` message from the other phone is
/// reported as [PairingCancelledException] by [receiveMessage]. Writes are
/// queued, so they go out in order.
class PairingChannel {
  new({
    required this._input,
    required this._socket,
    required this._keys,
    PairingFrameWorker? worker,
  }) : _codec = PairingFrameCodec(
         outgoing: _keys.outgoing.bytes,
         incoming: _keys.incoming.bytes,
         deflate: PairingFrameWorker.deflate,
       ),
       _givenWorker = worker;

  /// Bytes a frame may carry after its type byte (256 KiB: an offer of
  /// many languages; file data goes in smaller pieces).
  static const int maxPayload = PairingFrameCodec.maxPayload;

  /// Frames up to this size are handled on the caller's isolate.
  static const int _inlineLimit = 4 * 1024;

  static const int _tagLength = PairingFrameCodec.tagLength;

  final PairingByteReader _input;
  final Socket _socket;
  final PairingKeys _keys;
  final PairingFrameCodec _codec;
  final PairingFrameWorker? _givenWorker;
  PairingFrameWorker? _startedWorker;
  int _sent = 0;
  int _received = 0;
  bool _hashing = false;
  Set<String> _peerFeatures = const {};
  Future<void> _writes = Future.value();
  Object? _broken;

  /// Fails once the connection is closed for reading.
  late final Future<void> _inputClosed = _input.closed.then<void>(
    (_) => throw const PairingClosedException(),
  )..ignore();

  /// The short authentication string of this connection.
  String get sas => _keys.sas;

  /// The other phone's address.
  InternetAddress get remoteAddress => _socket.remoteAddress;

  /// What this phone's `hello` lists ([PairingFeature]).
  static List<String> get features => [
    if (PairingFrameWorker.inflates) PairingFeature.deflate,
  ];

  /// What the other phone's `hello` listed ([acceptHello]).
  Set<String> get peerFeatures => _peerFeatures;

  /// Whether file data may go compressed ([sendFileData]).
  bool get peerInflates => _peerFeatures.contains(PairingFeature.deflate);

  PairingFrameWorker get _worker =>
      _givenWorker ??
      (_startedWorker ??= PairingFrameWorker.start(
        outgoing: _keys.outgoing.bytes,
        incoming: _keys.incoming.bytes,
      ));

  /// Sends this phone's `hello`: [pairingProtocolVersion] and [features].
  Future<void> sendHello() => send('hello', {
    'v': pairingProtocolVersion,
    if (features.isNotEmpty) 'features': features,
  });

  /// Checks the other phone's [hello] ([checkHello]) and keeps what it
  /// lists ([peerFeatures]).
  void acceptHello(PairingMessage hello) {
    checkHello(hello);
    _peerFeatures = helloFeatures(hello);
  }

  /// Sends the message [type] with [fields].
  Future<void> send(String type, [Map<String, Object?> fields = const {}]) {
    final json = utf8.encode(jsonEncode({...fields, 't': type}));
    if (json.length > maxPayload) {
      throw ArgumentError.value(type, 'type', 'Message too long');
    }
    return _write(PairingFrameType.message, json);
  }

  /// Sends file data, at most [maxPayload] bytes, as it is.
  Future<void> sendData(List<int> bytes) {
    if (bytes.length > maxPayload) {
      throw ArgumentError.value(bytes.length, 'bytes', 'Chunk too long');
    }
    return _write(PairingFrameType.data, bytes);
  }

  /// Sends file data, at most [maxPayload] bytes: compressed when
  /// [compress], the other phone inflates ([peerInflates]) and it gets
  /// smaller. Returns the bytes of the payload that went across.
  Future<int> sendFileData(List<int> bytes, {bool compress = true}) {
    if (bytes.length > maxPayload) {
      throw ArgumentError.value(bytes.length, 'bytes', 'Chunk too long');
    }
    return _write(
      PairingFrameType.data,
      bytes,
      compress: compress && peerInflates,
    );
  }

  /// Hashes the file data received from now on, in the worker, until
  /// [finishHash].
  Future<void> startHash({required bool sha256, required bool sha1}) async {
    _checkUsable();
    _hashing = true;
    await _guard(() => _worker.startHash(sha256: sha256, sha1: sha1));
  }

  /// The hashes of the file data received since [startHash].
  Future<PairingDigests> finishHash() async {
    _checkUsable();
    _hashing = false;
    return await _guard(_worker.finishHash);
  }

  /// The next frame, which must arrive within [timeout].
  Future<PairingFrame> receive({required Duration timeout}) async {
    _checkUsable();
    try {
      final header = await _input.read(4, timeout: timeout);
      final length = ByteData.sublistView(header).getUint32(0);
      if (length <= _tagLength || length > maxPayload + 1 + _tagLength) {
        throw PairingProtocolException('Frame of $length bytes');
      }
      final sealed = await _input.read(length, timeout: timeout);
      final number = _received;
      final (type, payload) = length <= _inlineLimit && !_hashing
          ? _codec.open(number, sealed)
          : await _worker.open(number, sealed);
      _received++;
      return type == PairingFrameType.message
          ? _message(payload)
          : PairingData(payload);
    } on Object catch (error) {
      _break(error);
      rethrow;
    }
  }

  /// The next message, which must arrive within [timeout] and be one of
  /// [expected] (when given). Throws [PairingCancelledException] when the
  /// other phone cancelled, [PairingProtocolException] for file data or
  /// another message.
  Future<PairingMessage> receiveMessage({
    required Duration timeout,
    Set<String>? expected,
  }) async {
    final frame = await receive(timeout: timeout);
    final error = switch (frame) {
      PairingMessage(type: 'cancel') => const PairingCancelledException(),
      PairingMessage(:final type)
          when expected != null && !expected.contains(type) =>
        PairingProtocolException('Unexpected message $type'),
      PairingMessage() => null,
      PairingData() => const PairingProtocolException('Unexpected data'),
    };
    if (error != null) {
      _break(error);
      throw error;
    }
    return frame as PairingMessage;
  }

  /// Sends what is queued, then closes the connection.
  Future<void> close() async {
    try {
      await _writes;
      await _socket.close();
    } on Object {
      // Closing a broken connection.
    } finally {
      _socket.destroy();
      _stopWorker();
      await _input.cancel();
    }
  }

  /// Tries to tell the other phone ([reason]), then closes the
  /// connection; never throws.
  Future<void> cancel([String reason = 'cancelled']) async {
    if (_broken == null) {
      try {
        await send('cancel', {
          'reason': reason,
        }).timeout(const Duration(seconds: 2));
      } on Object {
        // The connection is gone already.
      }
    }
    _broken ??= const PairingCancelledException();
    destroy();
  }

  /// Closes the connection at once.
  void destroy() {
    _broken ??= const PairingClosedException();
    _socket.destroy();
    _stopWorker();
    unawaited(_input.cancel());
  }

  /// The channel can't be used after [error]; its worker stops.
  void _break(Object error) {
    _broken ??= error;
    _stopWorker();
  }

  void _stopWorker() {
    _startedWorker?.close();
    _givenWorker?.close();
  }

  Future<int> _write(int type, List<int> payload, {bool compress = false}) {
    _checkUsable();
    final write = _writes.then((_) async {
      final number = _sent++;
      final bytes = payload is Uint8List
          ? payload
          : Uint8List.fromList(payload);
      final Uint8List frame;
      var sent = bytes.length;
      if (type == PairingFrameType.data && compress) {
        final sealed = await _worker.sealData(number, bytes, compress: true);
        frame = sealed.frame;
        sent = sealed.sent;
      } else if (bytes.length <= _inlineLimit) {
        frame = _codec.seal(number, type, bytes);
      } else {
        frame = await _worker.seal(number, type, bytes);
      }
      try {
        _socket.add(frame);
        // A socket whose other end went away may never finish a flush.
        final flushed = _socket.flush()..ignore();
        await Future.any([flushed, _inputClosed]);
      } on Object catch (error) {
        _break(error);
        throw PairingClosedException('$error');
      }
      return sent;
    });
    // A failed write fails the later ones too, without an unhandled error.
    _writes = write.then(
      (_) {},
      onError: (Object error) {
        _break(error);
      },
    );
    return write;
  }

  Future<T> _guard<T>(Future<T> Function() work) async {
    try {
      return await work();
    } on Object catch (error) {
      _break(error);
      rethrow;
    }
  }

  void _checkUsable() {
    final broken = _broken;
    if (broken == null) return;
    throw broken is PairingException
        ? broken
        : PairingClosedException('$broken');
  }

  PairingMessage _message(Uint8List payload) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(payload));
    } on FormatException {
      throw const PairingProtocolException('Malformed message');
    }
    if (json is! Map<String, Object?>) {
      throw const PairingProtocolException('Message is not an object');
    }
    final type = json['t'];
    if (type is! String) {
      throw const PairingProtocolException('Message without a type');
    }
    return PairingMessage(type, json);
  }
}

/// Version of the messages inside the channel (`hello`'s `v`).
const pairingProtocolVersion = 1;

/// Throws [PairingProtocolException] unless [hello] speaks
/// [pairingProtocolVersion].
void checkHello(PairingMessage hello) {
  if (hello.fields['v'] != pairingProtocolVersion) {
    throw const PairingProtocolException('Unsupported protocol version');
  }
}

/// The features [hello] lists ([PairingFeature]); none from a phone of an
/// earlier version, and only the strings of a list.
Set<String> helloFeatures(PairingMessage hello) =>
    switch (hello.fields['features']) {
      final List<Object?> list => {...list.whereType<String>()},
      _ => const {},
    };
