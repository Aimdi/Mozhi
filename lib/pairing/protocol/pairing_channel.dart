import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_handshake.dart';

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

/// The encrypted frames of a pairing connection, after the
/// [PairingHandshake]:
///
/// * each frame is a 4-byte big-endian length, then that many bytes of
///   AES-256-GCM ciphertext and tag (one key per direction, the nonce the
///   frame's number in that direction, so a replayed, dropped or reordered
///   frame fails to decrypt like a changed one);
/// * the plaintext is a type byte and its payload: 1 for a message (a
///   UTF-8 JSON object, see [PairingMessage]), 2 for file data;
/// * a payload holds at most [maxPayload] bytes: a longer frame is refused
///   before it is read.
///
/// Anything that fails ends the channel: a frame that does not decrypt
/// ([PairingAuthenticationException]), a malformed or oversize one
/// ([PairingProtocolException]), a closed socket
/// ([PairingClosedException]) or a read that times out
/// ([PairingTimeoutException]). A `cancel` message from the other phone is
/// reported as [PairingCancelledException] by [receiveMessage]. Writes are
/// queued, so they go out in order.
class PairingChannel {
  new({required this._input, required this._socket, required this._keys});

  /// Bytes a frame may carry after its type byte (256 KiB: an offer of
  /// many languages; file data goes in smaller pieces).
  static const int maxPayload = 256 * 1024;

  static const _messageType = 1;
  static const _dataType = 2;
  static const _tagLength = 16;
  static final _cipher = DartAesGcm.with256bits();

  final PairingByteReader _input;
  final Socket _socket;
  final PairingKeys _keys;
  int _sent = 0;
  int _received = 0;
  Future<void> _writes = Future.value();
  Object? _broken;

  /// The short authentication string of this connection.
  String get sas => _keys.sas;

  /// The other phone's address.
  InternetAddress get remoteAddress => _socket.remoteAddress;

  /// Sends the message [type] with [fields].
  Future<void> send(String type, [Map<String, Object?> fields = const {}]) {
    final json = utf8.encode(jsonEncode({...fields, 't': type}));
    if (json.length > maxPayload) {
      throw ArgumentError.value(type, 'type', 'Message too long');
    }
    return _write(_messageType, json);
  }

  /// Sends file data, at most [maxPayload] bytes.
  Future<void> sendData(List<int> bytes) {
    if (bytes.length > maxPayload) {
      throw ArgumentError.value(bytes.length, 'bytes', 'Chunk too long');
    }
    return _write(_dataType, bytes);
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
      final List<int> plain;
      try {
        plain = _cipher.decryptSync(
          SecretBox(
            Uint8List.sublistView(sealed, 0, length - _tagLength),
            nonce: _nonce(_received),
            mac: Mac(Uint8List.sublistView(sealed, length - _tagLength)),
          ),
          secretKeyData: _keys.incoming,
        );
      } on SecretBoxAuthenticationError {
        throw const PairingAuthenticationException();
      }
      _received++;
      final payload = Uint8List.sublistView(Uint8List.fromList(plain), 1);
      return switch (plain[0]) {
        _messageType => _message(payload),
        _dataType => PairingData(payload),
        final type => throw PairingProtocolException('Frame type $type'),
      };
    } on Object catch (error) {
      _broken ??= error;
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
      _broken ??= error;
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
    unawaited(_input.cancel());
  }

  Future<void> _write(int type, List<int> payload) {
    _checkUsable();
    final write = _writes.then((_) async {
      final plain = Uint8List(payload.length + 1)
        ..[0] = type
        ..setRange(1, payload.length + 1, payload);
      final box = _cipher.encryptSync(
        plain,
        secretKeyData: _keys.outgoing,
        nonce: _nonce(_sent++),
      );
      final length = box.cipherText.length + _tagLength;
      final frame = Uint8List(4 + length);
      ByteData.sublistView(frame).setUint32(0, length);
      frame
        ..setRange(4, 4 + box.cipherText.length, box.cipherText)
        ..setRange(4 + box.cipherText.length, 4 + length, box.mac.bytes);
      try {
        _socket.add(frame);
        await _socket.flush();
      } on Object catch (error) {
        _broken ??= error;
        throw PairingClosedException('$error');
      }
    });
    // A failed write fails the later ones too, without an unhandled error.
    _writes = write.catchError((Object _) {});
    return write;
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

  /// The 96-bit nonce of frame [number]: four zero bytes and the number.
  static Uint8List _nonce(int number) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce)
      ..setUint32(4, number ~/ 0x100000000)
      ..setUint32(8, number % 0x100000000);
    return nonce;
  }
}
