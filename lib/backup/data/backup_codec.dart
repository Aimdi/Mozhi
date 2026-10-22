import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/backup/data/gzip/backup_gzip.dart';
import 'package:mozhi/backup/models/backup_snapshot.dart';

/// The passphrase is wrong, or the backup was damaged or changed: its
/// AES-GCM tag does not verify (the two can't be told apart).
class BackupPassphraseException implements Exception {
  const new();

  @override
  String toString() =>
      'BackupPassphraseException: wrong passphrase, or the backup is '
      'damaged';
}

/// The bytes are not a Mozhi backup, or one written in a newer format
/// ([newerVersion]: the app needs an update to read it).
class BackupFormatException extends FormatException {
  const new({String message = 'Not a Mozhi backup', this.newerVersion = false})
    : super(message);

  /// Whether the backup was written by a newer version of the app.
  final bool newerVersion;
}

/// Argon2id parameters (RFC 9106, version 0x13) that turn a passphrase
/// into a backup key. Every backup's header records the ones it used.
class BackupKdf extends Equatable {
  const new({
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });

  /// Parses [toJson] output. Throws a [BackupFormatException] for other
  /// algorithms and parameters outside the bounds this app accepts
  /// ([maxMemory], [maxIterations], [maxParallelism], [maxWork]).
  factory fromJson(Object? json) {
    if (json case {
      'algorithm': 'argon2id',
      'version': 0x13,
      'memoryKiB': final int memory,
      'iterations': final int iterations,
      'parallelism': final int parallelism,
    }) {
      if (parallelism < 1 ||
          parallelism > maxParallelism ||
          memory < 8 * parallelism ||
          memory > maxMemory ||
          iterations < 1 ||
          iterations > maxIterations ||
          memory * iterations > maxWork) {
        throw const BackupFormatException(
          message: 'Unsupported KDF parameters',
        );
      }
      return BackupKdf(
        memory: memory,
        iterations: iterations,
        parallelism: parallelism,
      );
    }
    throw const BackupFormatException(message: 'Unsupported KDF');
  }

  /// What new backups use on Android: 64 MiB, 3 passes, one lane (about a
  /// second on a mid-range phone; docs/backup.md).
  static const standard = BackupKdf(
    memory: 65536,
    iterations: 3,
    parallelism: 1,
  );

  /// What new backups use in the web app: 19 MiB, 2 passes, one lane
  /// (OWASP's minimum for Argon2id). Argon2id runs as JavaScript there,
  /// about five times slower than on Android: [standard] would take over
  /// ten seconds on a mid-range phone's browser, this about two.
  static const browser = BackupKdf(
    memory: 19456,
    iterations: 2,
    parallelism: 1,
  );

  /// [browser] in the web app, [standard] elsewhere.
  static BackupKdf get platformDefault => kIsWeb ? browser : standard;

  // The bounds below are checked before the passphrase can be: whoever
  // crafts a file chooses how much work opening it takes. They leave room
  // above [standard] (and so [browser]), which every device must open
  // (sync files use these parameters too), but not much more: the most
  // they allow is under three times [standard]'s work, about 3 s on a
  // mid-range phone and half a minute in its browser.

  /// The largest [memory] a backup may ask for (KiB): 128 MiB, twice
  /// [standard]'s.
  static const maxMemory = 131072;

  /// The most [iterations] a backup may ask for.
  static const maxIterations = 8;

  /// The most lanes ([parallelism]) a backup may ask for.
  static const maxParallelism = 4;

  /// The most work ([memory] × [iterations], KiB passes) a backup may ask
  /// for: [maxMemory] with 4 passes, or 64 MiB with [maxIterations]
  /// (about 2.7 times [standard]'s).
  static const int maxWork = maxMemory * 4;

  /// Memory in KiB.
  final int memory;

  /// Passes over the memory.
  final int iterations;

  /// Lanes.
  final int parallelism;

  Map<String, Object?> toJson() => {
    'algorithm': 'argon2id',
    'version': 0x13,
    'memoryKiB': memory,
    'iterations': iterations,
    'parallelism': parallelism,
  };

  @override
  List<Object?> get props => [memory, iterations, parallelism];
}

/// A key derived from a passphrase ([BackupCodec.deriveKey]): the 32-byte
/// AES-256 [key], and the [salt] and [kdf] it was derived with (a
/// backup's header carries both).
///
/// Sync derives once and keeps it ([toJson]) instead of the passphrase.
/// [toString] never shows the key.
@immutable
class BackupKey {
  const new({required this.key, required this.salt, required this.kdf});

  /// Parses [toJson] output. Throws a [FormatException] when a field is
  /// missing or invalid.
  factory fromJson(Map<String, Object?> json) {
    if (json case {
      'key': final String key,
      'salt': final String salt,
      'kdf': final Object kdf,
    }) {
      final Uint8List keyBytes;
      final Uint8List saltBytes;
      try {
        keyBytes = base64Decode(key);
        saltBytes = base64Decode(salt);
      } on FormatException {
        throw const FormatException('Invalid backup key');
      }
      if (keyBytes.length != BackupCodec.keyLength ||
          saltBytes.length < BackupCodec.minSaltLength) {
        throw const FormatException('Invalid backup key');
      }
      return BackupKey(
        key: keyBytes,
        salt: saltBytes,
        kdf: BackupKdf.fromJson(kdf),
      );
    }
    throw const FormatException('Invalid backup key');
  }

  /// The AES-256 key ([BackupCodec.keyLength] bytes).
  final Uint8List key;

  /// The Argon2id salt.
  final Uint8List salt;

  /// The Argon2id parameters.
  final BackupKdf kdf;

  /// `{"key": base64, "salt": base64, "kdf": {...}}`: keep it in secure
  /// storage only.
  Map<String, Object?> toJson() => {
    'key': base64Encode(key),
    'salt': base64Encode(salt),
    'kdf': kdf.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is BackupKey &&
      listEquals(other.key, key) &&
      listEquals(other.salt, salt) &&
      other.kdf == kdf;

  @override
  int get hashCode => Object.hash(Object.hashAll(salt), kdf);

  @override
  String toString() => 'BackupKey($kdf)';
}

/// The readable start of a `.mozhibackup` file ([BackupCodec.readHeader]):
/// how its key is derived and encrypted, and when and by which app version
/// it was made. Anyone with the file can read it; everything else is
/// encrypted.
class BackupHeader extends Equatable {
  const new({
    required this.kdf,
    required this.salt,
    required this.nonce,
    required this.createdAt,
    required this.appVersion,
  });

  final BackupKdf kdf;
  final Uint8List salt;

  /// The AES-GCM nonce.
  final Uint8List nonce;

  /// When the backup was made.
  final DateTime createdAt;

  /// The app version that made it.
  final String appVersion;

  Map<String, Object?> toJson() => {
    'kdf': kdf.toJson(),
    'salt': base64Encode(salt),
    'cipher': 'aes-256-gcm',
    'nonce': base64Encode(nonce),
    'compression': 'gzip',
    'createdAt': createdAt.toUtc().toIso8601String(),
    'appVersion': appVersion,
  };

  @override
  List<Object?> get props => [kdf, salt, nonce, createdAt, appVersion];
}

/// Reads and writes `.mozhibackup` files: a [BackupSnapshot] encrypted for
/// a passphrase (docs/backup.md, "File format").
///
/// Layout: the [magic] `MOZHIBAK`, the [formatVersion] byte, the header
/// length (2 bytes, big-endian), the header ([BackupHeader] as UTF-8
/// JSON: Argon2id parameters, salt, nonce, createdAt, appVersion), then
/// AES-256-GCM (ciphertext and 16-byte tag) over gzip(JSON of the
/// snapshot). Everything before the ciphertext is the GCM associated data,
/// so changing the header (or the parameters in it) fails like a wrong
/// passphrase.
///
/// The key is Argon2id ([BackupKdf]) of the passphrase's UTF-8 bytes
/// (exactly as typed) and a random 16-byte salt per file. Nothing is
/// stored: neither the passphrase nor the key leave the call.
///
/// The slow parts (Argon2id, gzip, AES) run in a background isolate on
/// Android ([useIsolate]); in the web app, where there are no isolates,
/// Argon2id gives the page time between blocks and AES-GCM is the
/// browser's (Web Crypto).
class BackupCodec {
  const new({this._kdf, this._useIsolate});

  /// The first bytes of every backup.
  static const magic = 'MOZHIBAK';

  /// The layout version byte this codec writes and reads.
  static const formatVersion = 1;

  /// The file name extension (without the dot).
  static const fileExtension = 'mozhibackup';

  /// The MIME type backups are saved with.
  static const mimeType = 'application/octet-stream';

  /// AES-256 key length.
  static const keyLength = 32;

  /// Length of the salt of new keys.
  static const saltLength = 16;

  /// The shortest salt a backup may have.
  static const minSaltLength = 16;

  /// The largest backup file read (bytes).
  static const int maxFileLength = 64 * 1024 * 1024;

  /// The most a backup may decompress to (bytes).
  static const int maxDataLength = 128 * 1024 * 1024;

  static const _nonceLength = 12;
  static const _macLength = 16;
  static const _maxHeaderLength = 4096;

  /// Bytes before the header: magic, version byte, header length.
  static const int _prefixLength = 8 + 1 + 2;

  final BackupKdf? _kdf;
  final bool? _useIsolate;

  /// The Argon2id parameters of new keys ([BackupKdf.platformDefault]
  /// unless given).
  BackupKdf get kdf => _kdf ?? BackupKdf.platformDefault;

  /// Whether the slow parts run in a background isolate (not on the web).
  bool get useIsolate => _useIsolate ?? !kIsWeb;

  /// A new random salt.
  static Uint8List newSalt() {
    final random = Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < saltLength; i++) random.nextInt(256),
    ]);
  }

  /// The .mozhibackup bytes of [snapshot], encrypted for [passphrase].
  Future<Uint8List> encrypt(BackupSnapshot snapshot, String passphrase) async {
    final key = await deriveKey(passphrase, salt: newSalt());
    return await encryptWithKey(snapshot, key);
  }

  /// Throws [BackupPassphraseException] (wrong passphrase or damaged
  /// data: GCM fails) or [BackupFormatException] (not a Mozhi backup, or a
  /// newer format).
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) async {
    final key = await deriveKeyFor(bytes, passphrase);
    return await decryptWithKey(bytes, key);
  }

  /// For sync: derive once (Argon2id, slow) and reuse. Uses [kdf] unless
  /// [parameters] are given.
  Future<BackupKey> deriveKey(
    String passphrase, {
    required Uint8List salt,
    BackupKdf? parameters,
  }) async {
    final used = parameters ?? kdf;
    final message = (utf8.encode(passphrase), salt, used);
    final key = useIsolate
        ? await compute(_derive, message)
        : await _derive(message);
    return BackupKey(key: key, salt: salt, kdf: used);
  }

  /// The key of [passphrase] for the backup [bytes]: derived with the salt
  /// and parameters of its header. Throws [BackupFormatException] when
  /// [bytes] is not a backup.
  Future<BackupKey> deriveKeyFor(Uint8List bytes, String passphrase) {
    final header = readHeader(bytes);
    return deriveKey(passphrase, salt: header.salt, parameters: header.kdf);
  }

  /// Whether [bytes] (a backup) was encrypted with a key derived like
  /// [key]: the same salt and parameters (it says nothing about the
  /// passphrase). Throws [BackupFormatException] when [bytes] is not a
  /// backup.
  bool isEncryptedWith(Uint8List bytes, BackupKey key) {
    final header = readHeader(bytes);
    return header.kdf == key.kdf && listEquals(header.salt, key.salt);
  }

  /// The header of the backup [bytes] (readable without the passphrase).
  /// Throws [BackupFormatException] when [bytes] is not a backup or one in
  /// a newer format.
  BackupHeader readHeader(Uint8List bytes) => _parse(bytes).header;

  Future<Uint8List> encryptWithKey(
    BackupSnapshot snapshot,
    BackupKey key,
  ) async {
    final header = BackupHeader(
      kdf: key.kdf,
      salt: key.salt,
      nonce: _nonce(),
      createdAt: snapshot.createdAt,
      appVersion: snapshot.appVersion,
    );
    final prefix = _prefix(header);
    final message = (snapshot.toJson(), key.key, header.nonce, prefix);
    return useIsolate ? await compute(_seal, message) : await _seal(message);
  }

  /// Throws [BackupPassphraseException] when [key] does not open [bytes]
  /// (another passphrase or salt, or damaged data), and
  /// [BackupFormatException] when [bytes] is not a backup.
  Future<BackupSnapshot> decryptWithKey(Uint8List bytes, BackupKey key) async {
    final parsed = _parse(bytes);
    if (parsed.header.kdf != key.kdf ||
        !listEquals(parsed.header.salt, key.salt)) {
      throw const BackupPassphraseException();
    }
    final message = (bytes, parsed.prefixLength, parsed.header.nonce, key.key);
    final json = useIsolate
        ? await compute(_open, message)
        : await _open(message);
    try {
      return BackupSnapshot.fromJson(json);
    } on BackupSnapshotVersionException {
      throw const BackupFormatException(
        message: 'Newer backup format',
        newerVersion: true,
      );
    } on FormatException catch (error) {
      throw BackupFormatException(
        message: 'Invalid backup contents: ${error.message}',
      );
    }
  }

  static Uint8List _nonce() {
    final random = Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < _nonceLength; i++) random.nextInt(256),
    ]);
  }

  /// Magic, version byte, header length and header: the associated data.
  static Uint8List _prefix(BackupHeader header) {
    final json = utf8.encode(jsonEncode(header.toJson()));
    return (BytesBuilder(copy: false)
          ..add(ascii.encode(magic))
          ..addByte(formatVersion)
          ..addByte(json.length >> 8)
          ..addByte(json.length & 0xFF)
          ..add(json))
        .takeBytes();
  }

  /// The header of [bytes] and where the ciphertext starts.
  static ({BackupHeader header, int prefixLength}) _parse(Uint8List bytes) {
    if (bytes.length < _prefixLength ||
        ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != magic) {
      throw const BackupFormatException();
    }
    final version = bytes[8];
    if (version > formatVersion) {
      throw const BackupFormatException(
        message: 'Newer backup format',
        newerVersion: true,
      );
    }
    if (version != formatVersion) throw const BackupFormatException();
    final length = (bytes[9] << 8) | bytes[10];
    final end = _prefixLength + length;
    if (length == 0 ||
        length > _maxHeaderLength ||
        bytes.length < end + _macLength) {
      throw const BackupFormatException(message: 'Damaged backup header');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes.sublist(_prefixLength, end)));
    } on FormatException {
      throw const BackupFormatException(message: 'Damaged backup header');
    }
    if (json case {
      'kdf': final Object kdf,
      'salt': final String salt,
      'cipher': 'aes-256-gcm',
      'nonce': final String nonce,
      'compression': 'gzip',
      'createdAt': final String createdAt,
      'appVersion': final String appVersion,
    }) {
      final Uint8List saltBytes;
      final Uint8List nonceBytes;
      try {
        saltBytes = base64Decode(salt);
        nonceBytes = base64Decode(nonce);
      } on FormatException {
        throw const BackupFormatException(message: 'Damaged backup header');
      }
      final created = DateTime.tryParse(createdAt);
      if (saltBytes.length < minSaltLength ||
          nonceBytes.length != _nonceLength ||
          created == null) {
        throw const BackupFormatException(message: 'Damaged backup header');
      }
      return (
        header: BackupHeader(
          kdf: BackupKdf.fromJson(kdf),
          salt: saltBytes,
          nonce: nonceBytes,
          createdAt: created,
          appVersion: appVersion,
        ),
        prefixLength: end,
      );
    }
    throw const BackupFormatException(message: 'Damaged backup header');
  }
}

/// Argon2id of `(passphrase, salt, parameters)`.
Future<Uint8List> _derive((List<int>, Uint8List, BackupKdf) message) async {
  final (passphrase, salt, kdf) = message;
  final algorithm = DartArgon2id(
    memory: kdf.memory,
    iterations: kdf.iterations,
    parallelism: kdf.parallelism,
    hashLength: BackupCodec.keyLength,
    // Already in the background on Android; in the browser, a slice of
    // about 20 ms between the page's frames.
    maxIsolates: 0,
    blocksPerProcessingChunk: 1000,
  );
  final key = await algorithm.deriveKey(
    secretKey: SecretKey(passphrase),
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// `prefix ‖ AES-GCM(gzip(JSON))` of `(snapshot JSON, key, nonce,
/// prefix)`.
Future<Uint8List> _seal(
  (Map<String, Object?>, Uint8List, Uint8List, Uint8List) message,
) async {
  final (json, key, nonce, prefix) = message;
  final compressed = await gzipEncode(utf8.encode(jsonEncode(json)));
  final box = await AesGcm.with256bits().encrypt(
    compressed,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: prefix,
  );
  return (BytesBuilder(copy: false)
        ..add(prefix)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .takeBytes();
}

/// The snapshot JSON of `(file bytes, prefix length, nonce, key)`. Throws
/// [BackupPassphraseException] when the tag does not verify, and
/// [BackupFormatException] when the decrypted data is not gzip'd JSON.
Future<Map<String, Object?>> _open(
  (Uint8List, int, Uint8List, Uint8List) message,
) async {
  final (bytes, prefixLength, nonce, key) = message;
  final List<int> clear;
  try {
    clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        bytes.sublist(prefixLength, bytes.length - BackupCodec._macLength),
        nonce: nonce,
        mac: Mac(bytes.sublist(bytes.length - BackupCodec._macLength)),
      ),
      secretKey: SecretKey(key),
      aad: bytes.sublist(0, prefixLength),
    );
  } on SecretBoxAuthenticationError {
    throw const BackupPassphraseException();
  }
  final Object? json;
  try {
    final data = await gzipDecode(
      Uint8List.fromList(clear),
      maxLength: BackupCodec.maxDataLength,
    );
    json = jsonDecode(utf8.decode(data));
  } on FormatException catch (error) {
    throw BackupFormatException(
      message: 'Invalid backup contents: ${error.message}',
    );
  }
  if (json is! Map<String, Object?>) {
    throw const BackupFormatException(message: 'Invalid backup contents');
  }
  return json;
}
