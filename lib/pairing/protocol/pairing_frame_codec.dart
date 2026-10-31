import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

/// Compresses file data for a frame and inflates it again (raw deflate,
/// each frame on its own).
abstract interface class PairingDeflate {
  /// [bytes] compressed.
  Uint8List compress(Uint8List bytes);

  /// [bytes] inflated; throws [PairingProtocolException] when they are not
  /// a deflate stream or inflate to more than [limit] bytes (which is
  /// noticed before much more is inflated).
  Uint8List inflate(Uint8List bytes, {required int limit});
}

/// The hashes of one received file ([PairingFrameCodec.startHash]), as
/// lower-case hex; null for one that was not asked for.
typedef PairingDigests = ({String? sha256, String? sha1});

/// The plaintext types of a frame (the byte before its payload).
abstract final class PairingFrameType {
  /// A UTF-8 JSON object.
  static const message = 1;

  /// File data, as it is.
  static const data = 2;

  /// File data compressed with raw deflate ([PairingDeflate]), at most
  /// `PairingFrameCodec.maxPayload` bytes once inflated. Only sent to a
  /// phone whose `hello` lists the `deflate` feature.
  static const compressedData = 3;
}

/// Seals and opens the frames of one connection (see `PairingChannel`):
/// AES-256-GCM with one key per direction and the frame's number as
/// nonce, file data compressed when it gets smaller ([sealData], with a
/// [deflate]), and the hashes of the file being received ([startHash]).
///
/// Synchronous and self-contained, so it runs as well on a background
/// isolate (`PairingFrameWorker`) as on the caller's.
class PairingFrameCodec {
  new({required List<int> outgoing, required List<int> incoming, this.deflate})
    : _outgoing = SecretKeyData(outgoing),
      _incoming = SecretKeyData(incoming);

  /// Bytes a frame may carry after its type byte, compressed or inflated.
  static const int maxPayload = 256 * 1024;

  /// Bytes of the GCM tag at the end of a sealed frame.
  static const int tagLength = 16;

  /// Compressed data must save at least this much to be sent compressed.
  static const int _minSaving = 64;

  static final _cipher = DartAesGcm.with256bits();

  /// Null where nothing is compressed (a compressed frame is then refused).
  final PairingDeflate? deflate;

  final SecretKeyData _outgoing;
  final SecretKeyData _incoming;
  DartHashSink? _sha256;
  DartHashSink? _sha1;

  /// The frame [number] of this direction: its 4-byte length, then [type]
  /// and [payload] sealed.
  Uint8List seal(int number, int type, List<int> payload) {
    final plain = Uint8List(payload.length + 1)
      ..[0] = type
      ..setRange(1, payload.length + 1, payload);
    final box = _cipher.encryptSync(
      plain,
      secretKeyData: _outgoing,
      nonce: nonceOf(number),
    );
    final length = box.cipherText.length + tagLength;
    final frame = Uint8List(4 + length);
    ByteData.sublistView(frame).setUint32(0, length);
    frame
      ..setRange(4, 4 + box.cipherText.length, box.cipherText)
      ..setRange(4 + box.cipherText.length, 4 + length, box.mac.bytes);
    return frame;
  }

  /// File data [bytes] as frame [number]: compressed when [compress], a
  /// [deflate] is there and it gets smaller, else as it is. Also returns
  /// the payload's length in the frame.
  ({Uint8List frame, int sent}) sealData(
    int number,
    Uint8List bytes, {
    required bool compress,
  }) {
    final deflate = this.deflate;
    if (compress && deflate != null) {
      final compressed = deflate.compress(bytes);
      if (compressed.length + _minSaving <= bytes.length) {
        return (
          frame: seal(number, PairingFrameType.compressedData, compressed),
          sent: compressed.length,
        );
      }
    }
    return (
      frame: seal(number, PairingFrameType.data, bytes),
      sent: bytes.length,
    );
  }

  /// Opens [sealed] (a frame without its length) as frame [number] of the
  /// other direction: its type and payload, compressed data inflated (and
  /// typed [PairingFrameType.data]). File data is added to the hashes
  /// while a [startHash] runs.
  ///
  /// Throws [PairingAuthenticationException] for a frame that does not
  /// decrypt, [PairingProtocolException] for an unknown type or data that
  /// does not inflate (or not within [maxPayload]).
  (int, Uint8List) open(int number, Uint8List sealed) {
    if (sealed.length <= tagLength) {
      throw PairingProtocolException('Frame of ${sealed.length} bytes');
    }
    final List<int> plain;
    try {
      plain = _cipher.decryptSync(
        SecretBox(
          Uint8List.sublistView(sealed, 0, sealed.length - tagLength),
          nonce: nonceOf(number),
          mac: Mac(Uint8List.sublistView(sealed, sealed.length - tagLength)),
        ),
        secretKeyData: _incoming,
      );
    } on SecretBoxAuthenticationError {
      throw const PairingAuthenticationException();
    }
    final bytes = plain is Uint8List ? plain : Uint8List.fromList(plain);
    final payload = Uint8List.sublistView(bytes, 1);
    final (type, opened) = switch (bytes[0]) {
      PairingFrameType.message => (PairingFrameType.message, payload),
      PairingFrameType.data => (PairingFrameType.data, payload),
      PairingFrameType.compressedData when deflate != null => (
        PairingFrameType.data,
        deflate!.inflate(payload, limit: maxPayload),
      ),
      final other => throw PairingProtocolException('Frame type $other'),
    };
    if (type == PairingFrameType.data) {
      _sha256?.add(opened);
      _sha1?.add(opened);
    }
    return (type, opened);
  }

  /// Hashes the file data opened from now on ([finishHash]): with SHA-256
  /// and/or SHA-1.
  void startHash({required bool sha256, required bool sha1}) {
    _sha256 = sha256 ? const DartSha256().newHashSink() : null;
    _sha1 = sha1 ? const DartSha1().newHashSink() : null;
  }

  /// The hashes since [startHash]; hashing stops.
  PairingDigests finishHash() {
    final digests = (sha256: _hex(_sha256), sha1: _hex(_sha1));
    _sha256 = null;
    _sha1 = null;
    return digests;
  }

  static String? _hex(DartHashSink? sink) {
    if (sink == null) return null;
    sink.close();
    final buffer = StringBuffer();
    for (final byte in sink.hashSync().bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// The 96-bit nonce of frame [number]: four zero bytes and the number.
  static Uint8List nonceOf(int number) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce)
      ..setUint32(4, number ~/ 0x100000000)
      ..setUint32(8, number % 0x100000000);
    return nonce;
  }
}
