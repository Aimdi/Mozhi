import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// The history could not be decrypted: the value is not one written by
/// [HistoryCipher.encrypt] with this key (wrong key, damaged data).
class HistoryCipherException implements Exception {
  const new([this.message = 'History could not be decrypted']);

  final String message;

  @override
  String toString() => 'HistoryCipherException: $message';
}

/// AES-256-GCM for the history stored on the device.
///
/// [encrypt] returns `prefix + base64(nonce ‖ ciphertext ‖ tag)`: a random
/// 96-bit nonce per call and a 128-bit tag over the ciphertext and the
/// associated data (by default [associatedData]; another one for each other
/// kind of value encrypted with the same key, e.g. the history's deletion
/// records), so a value encrypted for something else is rejected.
///
/// Large values are encrypted and decrypted in a background isolate
/// (from [isolateThreshold] UTF-16 code units, not on the web, where the
/// browser's Web Crypto does the work when the page is a secure context).
class HistoryCipher {
  const new({this.isolateThreshold = 64 * 1024});

  /// Marks a value written by [encrypt] (and its format version).
  static const prefix = 'mozhi-aesgcm1:';

  /// Key length in bytes (AES-256).
  static const keyLength = 32;

  static const _nonceLength = 12;
  static const _macLength = 16;

  /// Bound into every value as GCM associated data.
  static const associatedData = 'mozhi.history';

  /// From this many UTF-16 code units, [encrypt] and [decrypt] run in a
  /// background isolate (never on the web).
  final int isolateThreshold;

  /// A new random 256-bit key.
  Future<Uint8List> newKey() async {
    final random = Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < keyLength; i++) random.nextInt(256),
    ]);
  }

  /// Whether [stored] was written by [encrypt] (as opposed to the
  /// plaintext JSON stored by older versions).
  bool isEncrypted(String stored) => stored.startsWith(prefix);

  /// Length of the value [encrypt] returns for a plaintext of
  /// [plaintextBytes] UTF-8 bytes.
  static int encryptedLength(int plaintextBytes) =>
      prefix.length +
      4 * ((_nonceLength + plaintextBytes + _macLength + 2) ~/ 3);

  /// Encrypts [plaintext] with [key] ([keyLength] bytes), binding
  /// [aad] (default [associatedData]) into the tag.
  Future<String> encrypt(
    String plaintext,
    List<int> key, {
    String aad = associatedData,
  }) {
    _checkKey(key);
    final message = (plaintext, key, aad);
    if (_inBackground(plaintext.length)) {
      return compute(_encryptMessage, message);
    }
    return _encryptMessage(message);
  }

  /// Decrypts a value written by [encrypt] with [key] and [aad]. Throws
  /// [HistoryCipherException] when it is not one (wrong key or associated
  /// data, damaged or not encrypted).
  Future<String> decrypt(
    String stored,
    List<int> key, {
    String aad = associatedData,
  }) async {
    _checkKey(key);
    if (!isEncrypted(stored)) {
      throw const HistoryCipherException('Not an encrypted history');
    }
    final message = (stored, key, aad);
    final String? plaintext;
    if (_inBackground(stored.length)) {
      plaintext = await compute(_decryptMessage, message);
    } else {
      plaintext = await _decryptMessage(message);
    }
    if (plaintext == null) throw const HistoryCipherException();
    return plaintext;
  }

  bool _inBackground(int length) => !kIsWeb && length >= isolateThreshold;

  static void _checkKey(List<int> key) {
    if (key.length != keyLength) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes long');
    }
  }

  static Future<String> _encryptMessage(
    (String, List<int>, String) message,
  ) async {
    final (plaintext, key, aad) = message;
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
      aad: utf8.encode(aad),
    );
    return '$prefix${base64Encode(box.concatenation())}';
  }

  /// The plaintext, or null when [message] does not decrypt.
  static Future<String?> _decryptMessage(
    (String, List<int>, String) message,
  ) async {
    final (stored, key, aad) = message;
    try {
      final bytes = base64Decode(stored.substring(prefix.length));
      final box = SecretBox.fromConcatenation(
        bytes,
        nonceLength: _nonceLength,
        macLength: _macLength,
        copy: false,
      );
      final clear = await AesGcm.with256bits().decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode(aad),
      );
      return utf8.decode(clear);
    } on Object {
      // Bad base64, too short, wrong tag or invalid UTF-8.
      return null;
    }
  }
}
