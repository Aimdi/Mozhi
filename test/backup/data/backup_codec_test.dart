import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/models/backup_snapshot.dart';

/// Small parameters: fast tests.
const _kdf = BackupKdf(memory: 256, iterations: 2, parallelism: 1);
const _codec = BackupCodec(kdf: _kdf, useIsolate: false);

final _snapshot = BackupSnapshot(
  createdAt: DateTime.utc(2026, 10, 22, 13, 5),
  appVersion: '1.4.0+12',
  sections: const {
    'history': BackupSectionData(
      version: 1,
      data: {
        'entries': [
          {'id': '1', 'text': 'Guten Abend', 'translation': 'Good evening'},
        ],
      },
    ),
    'presets': BackupSectionData(version: 1, data: null),
  },
);

/// The header JSON of [bytes] and where it ends.
(Map<String, Object?>, int) _header(Uint8List bytes) {
  final length = (bytes[9] << 8) | bytes[10];
  return (
    jsonDecode(utf8.decode(bytes.sublist(11, 11 + length)))
        as Map<String, Object?>,
    11 + length,
  );
}

/// [bytes] with the header replaced by [header] (same layout otherwise).
Uint8List _withHeader(Uint8List bytes, Map<String, Object?> header) {
  final (_, end) = _header(bytes);
  final json = utf8.encode(jsonEncode(header));
  return Uint8List.fromList([
    ...bytes.sublist(0, 9),
    json.length >> 8,
    json.length & 0xFF,
    ...json,
    ...bytes.sublist(end),
  ]);
}

Matcher _formatError({bool newer = false}) => throwsA(
  isA<BackupFormatException>().having(
    (e) => e.newerVersion,
    'newerVersion',
    newer,
  ),
);

void main() {
  group('BackupCodec', () {
    late Uint8List bytes;

    setUpAll(() async {
      bytes = await _codec.encrypt(_snapshot, 'correct horse battery');
    });

    test('decrypts what it encrypted with the passphrase', () async {
      expect(await _codec.decrypt(bytes, 'correct horse battery'), _snapshot);
    });

    test('starts with the magic, the format byte and a JSON header', () {
      expect(ascii.decode(bytes.sublist(0, 8)), 'MOZHIBAK');
      expect(bytes[8], 1);
      final (header, _) = _header(bytes);
      expect(header['kdf'], {
        'algorithm': 'argon2id',
        'version': 0x13,
        'memoryKiB': 256,
        'iterations': 2,
        'parallelism': 1,
      });
      expect(header['cipher'], 'aes-256-gcm');
      expect(header['compression'], 'gzip');
      expect(header['createdAt'], '2026-10-22T13:05:00.000Z');
      expect(header['appVersion'], '1.4.0+12');
      expect(base64Decode(header['salt']! as String), hasLength(16));
      expect(base64Decode(header['nonce']! as String), hasLength(12));
    });

    test('never contains the data or the passphrase in clear', () {
      final text = latin1.decode(bytes);
      expect(text, isNot(contains('Guten')));
      expect(text, isNot(contains('history')));
      expect(text, isNot(contains('horse')));
    });

    test('reads the header without the passphrase', () {
      final header = _codec.readHeader(bytes);

      expect(header.kdf, _kdf);
      expect(header.createdAt, DateTime.utc(2026, 10, 22, 13, 5));
      expect(header.appVersion, '1.4.0+12');
      expect(header.salt, hasLength(16));
      expect(header.nonce, hasLength(12));
    });

    test('a fresh salt and nonce per file', () async {
      final again = await _codec.encrypt(_snapshot, 'correct horse battery');

      expect(
        _codec.readHeader(again).salt,
        isNot(_codec.readHeader(bytes).salt),
      );
      expect(
        _codec.readHeader(again).nonce,
        isNot(_codec.readHeader(bytes).nonce),
      );
    });

    test('a wrong passphrase fails with one clear error', () async {
      await expectLater(
        _codec.decrypt(bytes, 'correct horse batterY'),
        throwsA(isA<BackupPassphraseException>()),
      );
    });

    test('any changed byte after the magic fails like a wrong '
        'passphrase', () async {
      final (_, end) = _header(bytes);
      // The header length, inside the header JSON, inside the ciphertext
      // and in the tag.
      for (final index in [end - 3, end + 1, bytes.length - 1]) {
        final changed = Uint8List.fromList(bytes);
        changed[index] ^= 0x01;
        await expectLater(
          _codec.decrypt(changed, 'correct horse battery'),
          throwsA(
            anyOf(
              isA<BackupPassphraseException>(),
              isA<BackupFormatException>(),
            ),
          ),
          reason: 'byte $index',
        );
      }
    });

    test('a header changed to valid JSON fails like a wrong '
        'passphrase', () async {
      final (header, _) = _header(bytes);
      final changed = _withHeader(bytes, {...header, 'appVersion': '9.9.9'});

      expect(_codec.readHeader(changed).appVersion, '9.9.9');
      await expectLater(
        _codec.decrypt(changed, 'correct horse battery'),
        throwsA(isA<BackupPassphraseException>()),
      );
    });

    test('ciphertext cut short fails', () async {
      await expectLater(
        _codec.decrypt(
          bytes.sublist(0, bytes.length - 20),
          'correct horse battery',
        ),
        throwsA(
          anyOf(isA<BackupPassphraseException>(), isA<BackupFormatException>()),
        ),
      );
    });

    group('refuses what is not a backup', () {
      test('other files', () {
        for (final other in [
          <int>[],
          utf8.encode('MOZHIBA'),
          utf8.encode('[{"id": "1"}]'),
          utf8.encode('NOTMOZHI\x01\x00\x02{}0123456789abcdef'),
        ]) {
          expect(
            () => _codec.readHeader(Uint8List.fromList(other)),
            _formatError(),
          );
        }
      });

      test('a newer format byte, saying so', () {
        final newer = Uint8List.fromList(bytes)..[8] = 2;

        expect(() => _codec.readHeader(newer), _formatError(newer: true));
      });

      test('format byte 0', () {
        final zero = Uint8List.fromList(bytes)..[8] = 0;

        expect(() => _codec.readHeader(zero), _formatError());
      });

      test('a header length beyond the file', () {
        final long = Uint8List.fromList(bytes)
          ..[9] = 0x0F
          ..[10] = 0xFF;

        expect(() => _codec.readHeader(long), _formatError());
        expect(() => _codec.readHeader(bytes.sublist(0, 30)), _formatError());
      });

      test('an empty header', () {
        final empty = Uint8List.fromList([...bytes.sublist(0, 9), 0, 0]);

        expect(() => _codec.readHeader(empty), _formatError());
      });

      test('a damaged header', () {
        final (header, _) = _header(bytes);
        for (final damaged in <Map<String, Object?>>[
          {...header, 'cipher': 'chacha20'},
          {...header, 'compression': 'zstd'},
          {...header, 'salt': 'not base64!'},
          {...header, 'salt': base64Encode(List.filled(8, 0))},
          {...header, 'nonce': base64Encode(List.filled(16, 0))},
          {...header, 'createdAt': 'yesterday'},
          {...header, 'appVersion': null},
          {...header, 'kdf': 'argon2id'},
          {
            ...header,
            'kdf': {...(header['kdf']! as Map), 'algorithm': 'scrypt'},
          },
        ]) {
          expect(
            () => _codec.readHeader(_withHeader(bytes, damaged)),
            _formatError(),
            reason: '$damaged',
          );
        }
        // Not JSON at all.
        final notJson = Uint8List.fromList(bytes);
        notJson[11] = 0xFF;
        expect(() => _codec.readHeader(notJson), _formatError());
      });

      test('KDF parameters beyond the bounds (no huge allocation)', () {
        final (header, _) = _header(bytes);
        final kdf = header['kdf']! as Map<String, Object?>;
        for (final change in <Map<String, Object?>>[
          {'memoryKiB': BackupKdf.maxMemory + 1},
          {'memoryKiB': 4},
          {'iterations': 0},
          {'iterations': BackupKdf.maxIterations + 1},
          {'parallelism': 0},
          {'parallelism': BackupKdf.maxParallelism + 1},
          // Each within its bound, but too much work together.
          {'memoryKiB': BackupKdf.maxMemory, 'iterations': 5},
          {'memoryKiB': 65537, 'iterations': BackupKdf.maxIterations},
        ]) {
          expect(
            () => _codec.readHeader(
              _withHeader(bytes, {
                ...header,
                'kdf': {...kdf, ...change},
              }),
            ),
            _formatError(),
            reason: '$change',
          );
        }
      });
    });

    group('KDF bounds', () {
      Map<String, Object?> json(int memory, int iterations, int lanes) =>
          BackupKdf(
            memory: memory,
            iterations: iterations,
            parallelism: lanes,
          ).toJson();

      test('leave room above the platform defaults, but not much', () {
        expect(BackupKdf.maxMemory, 128 * 1024);
        expect(BackupKdf.maxIterations, 8);
        expect(BackupKdf.maxParallelism, 4);
        // Under three times the work of Android's parameters.
        const standard = BackupKdf.standard;
        expect(
          BackupKdf.maxWork,
          lessThan(3 * standard.memory * standard.iterations),
        );
        for (final kdf in [BackupKdf.standard, BackupKdf.browser]) {
          expect(
            BackupKdf.fromJson(kdf.toJson()),
            kdf,
            reason: 'a file made on Android opens in the web app and back',
          );
        }
      });

      test('accept parameters at the bounds', () {
        for (final (memory, iterations, lanes) in [
          (BackupKdf.maxMemory, 4, BackupKdf.maxParallelism),
          (65536, BackupKdf.maxIterations, 1),
          (8 * BackupKdf.maxParallelism, 1, BackupKdf.maxParallelism),
        ]) {
          expect(
            BackupKdf.fromJson(json(memory, iterations, lanes)),
            BackupKdf(
              memory: memory,
              iterations: iterations,
              parallelism: lanes,
            ),
            reason: '$memory KiB, $iterations passes, $lanes lanes',
          );
        }
      });

      test('refuse parameters just beyond them', () {
        for (final (memory, iterations, lanes) in [
          (BackupKdf.maxMemory + 1, 1, 1),
          (65536, BackupKdf.maxIterations + 1, 1),
          (65536, 1, BackupKdf.maxParallelism + 1),
          (BackupKdf.maxMemory, 5, 1),
          (BackupKdf.maxWork ~/ 8 + 1, 8, 1),
          // Old bounds (256 MiB, 16 passes, 8 lanes) no longer pass.
          (262144, 3, 1),
          (65536, 16, 1),
          (65536, 3, 8),
        ]) {
          expect(
            () => BackupKdf.fromJson(json(memory, iterations, lanes)),
            _formatError(),
            reason: '$memory KiB, $iterations passes, $lanes lanes',
          );
        }
      });
    });

    test('a snapshot in a newer format says so', () async {
      final key = await _codec.deriveKeyFor(bytes, 'pass phrase');
      final newer = await _sealRaw(key, {
        ..._snapshot.toJson(),
        'formatVersion': 2,
      });

      await expectLater(
        _codec.decryptWithKey(newer, key),
        _formatError(newer: true),
      );
    });

    test('decrypted data that is not a snapshot is a format error', () async {
      final key = await _codec.deriveKeyFor(bytes, 'pass phrase');
      for (final plaintext in [
        utf8.encode('{"format": "mozhi-backup"}'),
        utf8.encode('not gzip'),
        utf8.encode('[1, 2]'),
      ]) {
        final sealed = await _sealBytes(
          key,
          plaintext,
          gzipped: !utf8.decode(plaintext).startsWith('not'),
        );
        await expectLater(
          _codec.decryptWithKey(sealed, key),
          _formatError(),
          reason: utf8.decode(plaintext),
        );
      }
    });

    group('passphrase normalisation', () {
      // "Việt" composed (NFC), and as typed with combining marks.
      const composed = 'Vi\u1EC7t nam ph\u1EDD';
      const decomposed = 'Vie\u0323\u0302t nam pho\u031B\u0300';

      test('either way of typing a letter opens the backup', () async {
        final sealed = await _codec.encrypt(_snapshot, decomposed);
        expect(await _codec.decrypt(sealed, composed), _snapshot);
        expect(await _codec.decrypt(sealed, decomposed), _snapshot);
        final other = await _codec.encrypt(_snapshot, composed);
        expect(await _codec.decrypt(other, decomposed), _snapshot);
      });

      test('keys are derived from the NFC passphrase', () async {
        final salt = BackupCodec.newSalt();
        final nfc = await _codec.deriveKey(composed, salt: salt);
        expect(await _codec.deriveKey(decomposed, salt: salt), nfc);
        expect(
          await _codec.deriveKey(decomposed, salt: salt, asTyped: true),
          isNot(nfc),
        );
        expect(
          await _codec.deriveKey(composed, salt: salt, asTyped: true),
          nfc,
        );
      });

      Future<Uint8List> legacy(String passphrase) async {
        // How backups were encrypted before: the passphrase as typed.
        final key = await _codec.deriveKey(
          passphrase,
          salt: BackupCodec.newSalt(),
          asTyped: true,
        );
        return await _codec.encryptWithKey(_snapshot, key);
      }

      test('a backup made with the passphrase as typed still opens', () async {
        final old = await legacy(decomposed);
        expect(await _codec.decrypt(old, decomposed), _snapshot);
        await expectLater(
          _codec.decrypt(old, 'Vie\u0323\u0302t nam pho'),
          throwsA(isA<BackupPassphraseException>()),
        );
      });

      test('unlockKeyFor finds the key that opens the file', () async {
        final old = await legacy(decomposed);
        final typed = await _codec.unlockKeyFor(old, decomposed);
        expect(await _codec.decryptWithKey(old, typed), _snapshot);
        expect(
          typed,
          await _codec.deriveKeyFor(old, decomposed, asTyped: true),
        );

        final current = await _codec.encrypt(_snapshot, composed);
        final nfc = await _codec.unlockKeyFor(current, decomposed);
        expect(nfc, await _codec.deriveKeyFor(current, composed));
        expect(await _codec.unlockKeyFor(current, composed), nfc);

        // Neither opens it: the NFC key, which fails like a wrong one.
        final wrong = await _codec.unlockKeyFor(old, 'Vie\u0323\u0302t');
        expect(wrong, await _codec.deriveKeyFor(old, 'Vi\u1EC7t'));
        await expectLater(
          _codec.decryptWithKey(old, wrong),
          throwsA(isA<BackupPassphraseException>()),
        );
      });

      test('unlockKeyOf says when the key is of the passphrase as typed, '
          'and a file written again with the NFC key opens with it', () async {
        final old = await legacy(decomposed);
        final typed = await _codec.unlockKeyOf(old, decomposed);
        expect(typed.asTyped, isTrue);
        expect(
          typed.key,
          await _codec.deriveKeyFor(old, decomposed, asTyped: true),
        );

        // Written again with the NFC key (sync does that once).
        final snapshot = await _codec.decryptWithKey(old, typed.key);
        final nfcKey = await _codec.deriveKey(
          decomposed,
          salt: BackupCodec.newSalt(),
        );
        final rekeyed = await _codec.encryptWithKey(snapshot, nfcKey);
        for (final passphrase in [decomposed, composed]) {
          final unlocked = await _codec.unlockKeyOf(rekeyed, passphrase);
          expect(unlocked.asTyped, isFalse);
          expect(unlocked.key, nfcKey);
          expect(await _codec.decryptWithKey(rekeyed, unlocked.key), _snapshot);
        }

        // A passphrase already in NFC, and one that opens nothing.
        final current = await _codec.encrypt(_snapshot, composed);
        expect((await _codec.unlockKeyOf(current, composed)).asTyped, isFalse);
        expect(
          (await _codec.unlockKeyOf(old, 'Vie\u0323\u0302t')).asTyped,
          isFalse,
        );
      });

      test('unlockKeyFor refuses what is not a backup', () async {
        await expectLater(
          _codec.unlockKeyFor(Uint8List(3), decomposed),
          _formatError(),
        );
      });
    });

    group('keys', () {
      test('derive once and reuse (sync)', () async {
        final key = await _codec.deriveKey(
          'sync phrase',
          salt: BackupCodec.newSalt(),
        );
        final first = await _codec.encryptWithKey(_snapshot, key);
        final second = await _codec.encryptWithKey(_snapshot, key);

        expect(await _codec.decryptWithKey(first, key), _snapshot);
        expect(await _codec.decrypt(second, 'sync phrase'), _snapshot);
        expect(_codec.readHeader(first).salt, _codec.readHeader(second).salt);
        expect(
          _codec.readHeader(first).nonce,
          isNot(_codec.readHeader(second).nonce),
        );
      });

      test('Argon2id matches the reference implementation', () async {
        // argon2 reference test vector (Argon2id v19, t=2, m=256 KiB, p=1).
        final key = await _codec.deriveKey(
          'password',
          salt: Uint8List.fromList(utf8.encode('somesalt')),
        );

        expect(
          key.key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe',
        );
      });

      test('deriveKeyFor uses the salt and parameters of the file', () async {
        const other = BackupCodec(
          kdf: BackupKdf(memory: 64, iterations: 1, parallelism: 1),
          useIsolate: false,
        );
        final key = await other.deriveKeyFor(bytes, 'correct horse battery');

        expect(key.kdf, _kdf);
        expect(key.salt, _codec.readHeader(bytes).salt);
        expect(other.isEncryptedWith(bytes, key), isTrue);
        expect(await other.decryptWithKey(bytes, key), _snapshot);
      });

      test('isEncryptedWith tells another salt or KDF apart', () async {
        final key = await _codec.deriveKeyFor(bytes, 'anything');
        final otherSalt = await _codec.deriveKey(
          'anything',
          salt: BackupCodec.newSalt(),
        );
        final otherKdf = BackupKey(
          key: key.key,
          salt: key.salt,
          kdf: const BackupKdf(memory: 512, iterations: 2, parallelism: 1),
        );

        expect(_codec.isEncryptedWith(bytes, key), isTrue);
        expect(_codec.isEncryptedWith(bytes, otherSalt), isFalse);
        expect(_codec.isEncryptedWith(bytes, otherKdf), isFalse);
        expect(() => _codec.isEncryptedWith(Uint8List(3), key), _formatError());
      });

      test('a key of another salt is refused before decrypting', () async {
        final otherSalt = await _codec.deriveKey(
          'correct horse battery',
          salt: BackupCodec.newSalt(),
        );

        await expectLater(
          _codec.decryptWithKey(bytes, otherSalt),
          throwsA(isA<BackupPassphraseException>()),
        );
      });

      test('a key with the right salt but the wrong passphrase', () async {
        final wrong = await _codec.deriveKeyFor(bytes, 'wrong');

        await expectLater(
          _codec.decryptWithKey(bytes, wrong),
          throwsA(isA<BackupPassphraseException>()),
        );
      });

      test('round-trip through JSON (secure storage)', () async {
        final key = await _codec.deriveKeyFor(bytes, 'correct horse battery');
        final json =
            jsonDecode(jsonEncode(key.toJson())) as Map<String, Object?>;
        final restored = BackupKey.fromJson(json);

        expect(restored, key);
        expect(restored.hashCode, key.hashCode);
        expect(await _codec.decryptWithKey(bytes, restored), _snapshot);
      });

      test('fromJson refuses invalid keys', () {
        final valid = BackupKey(
          key: Uint8List(32),
          salt: Uint8List(16),
          kdf: _kdf,
        ).toJson();
        for (final json in <Map<String, Object?>>[
          {},
          {...valid, 'key': base64Encode(Uint8List(31))},
          {...valid, 'key': 'not base64!'},
          {...valid, 'salt': base64Encode(Uint8List(4))},
          {
            ...valid,
            'kdf': {'algorithm': 'pbkdf2'},
          },
        ]) {
          expect(
            () => BackupKey.fromJson(json),
            throwsFormatException,
            reason: '$json',
          );
        }
      });

      test('never shows the key', () {
        final key = BackupKey(
          key: Uint8List.fromList(List.filled(32, 0xAB)),
          salt: Uint8List(16),
          kdf: _kdf,
        );

        expect(key.toString(), isNot(contains('171')));
        expect(key.toString(), isNot(contains('q6ur')));
        expect(
          key,
          isNot(BackupKey(key: Uint8List(32), salt: key.salt, kdf: _kdf)),
        );
      });
    });

    test('works in a background isolate', () async {
      const isolated = BackupCodec(kdf: _kdf, useIsolate: true);
      final sealed = await isolated.encrypt(_snapshot, 'pass');

      expect(await isolated.decrypt(sealed, 'pass'), _snapshot);
      expect(await _codec.decrypt(sealed, 'pass'), _snapshot);
    });

    test('platform defaults', () {
      expect(const BackupCodec().kdf, BackupKdf.standard);
      expect(BackupKdf.platformDefault, BackupKdf.standard);
      expect(const BackupCodec().useIsolate, isTrue);
      expect(BackupKdf.standard.memory, 65536);
      expect(BackupKdf.browser.memory, 19456);
    });

    test('the standard parameters round-trip', () async {
      const standard = BackupCodec();
      final sealed = await standard.encrypt(_snapshot, 'pass');

      expect(standard.readHeader(sealed).kdf, BackupKdf.standard);
      expect(await standard.decrypt(sealed, 'pass'), _snapshot);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('exceptions describe themselves', () {
    expect(
      const BackupFileTooLargeException().toString(),
      'BackupFileTooLargeException',
    );
    expect(
      const BackupPassphraseException().toString(),
      contains('wrong passphrase'),
    );
    expect(const BackupFormatException().message, 'Not a Mozhi backup');
    expect(const BackupFormatException().newerVersion, isFalse);
  });
}

/// [json] gzip'd and sealed with [key] the way the codec does it.
Future<Uint8List> _sealRaw(BackupKey key, Map<String, Object?> json) =>
    _sealBytes(key, utf8.encode(jsonEncode(json)));

/// [plaintext] (gzip'd when [gzipped]) sealed with [key] behind a valid
/// header.
Future<Uint8List> _sealBytes(
  BackupKey key,
  List<int> plaintext, {
  bool gzipped = true,
}) async {
  final nonce = Uint8List.fromList(List.filled(12, 7));
  final header = BackupHeader(
    kdf: key.kdf,
    salt: key.salt,
    nonce: nonce,
    createdAt: DateTime.utc(2026),
    appVersion: '1',
  );
  final json = utf8.encode(jsonEncode(header.toJson()));
  final prefix = Uint8List.fromList([
    ...ascii.encode('MOZHIBAK'),
    1,
    json.length >> 8,
    json.length & 0xFF,
    ...json,
  ]);
  final data = gzipped ? gzip.encode(plaintext) : plaintext;
  final box = await AesGcm.with256bits().encrypt(
    data,
    secretKey: SecretKey(key.key),
    nonce: nonce,
    aad: prefix,
  );
  return Uint8List.fromList([...prefix, ...box.cipherText, ...box.mac.bytes]);
}
