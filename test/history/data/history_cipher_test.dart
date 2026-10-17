import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/data/history_cipher.dart';

void main() {
  group(HistoryCipher, () {
    const cipher = HistoryCipher();
    final key = List<int>.generate(HistoryCipher.keyLength, (i) => i);
    final otherKey = List<int>.generate(
      HistoryCipher.keyLength,
      (i) => 255 - i,
    );
    const text = '[{"text":"Guten Morgen","translation":"காலை வணக்கம் 👋"}]';

    test('makes random 256-bit keys', () async {
      final first = await cipher.newKey();
      final second = await cipher.newKey();

      expect(first, hasLength(32));
      expect(second, hasLength(32));
      expect(first, isNot(second));
    });

    test('round-trips text, without showing it', () async {
      final encrypted = await cipher.encrypt(text, key);

      expect(encrypted, startsWith(HistoryCipher.prefix));
      expect(cipher.isEncrypted(encrypted), isTrue);
      expect(encrypted, isNot(contains('Morgen')));
      expect(await cipher.decrypt(encrypted, key), text);
    });

    test('uses a new nonce every time', () async {
      expect(
        await cipher.encrypt(text, key),
        isNot(await cipher.encrypt(text, key)),
      );
    });

    test('reports the length it stores', () async {
      for (final plain in ['', 'a', 'ab', 'abc', text]) {
        final encrypted = await cipher.encrypt(plain, key);
        expect(
          encrypted.length,
          HistoryCipher.encryptedLength(utf8.encode(plain).length),
        );
      }
    });

    test('recognises plaintext JSON as not encrypted', () {
      expect(cipher.isEncrypted('[]'), isFalse);
      expect(cipher.isEncrypted(''), isFalse);
    });

    test('rejects the wrong key', () async {
      final encrypted = await cipher.encrypt(text, key);

      await expectLater(
        cipher.decrypt(encrypted, otherKey),
        throwsA(isA<HistoryCipherException>()),
      );
    });

    test('rejects tampered data', () async {
      final encrypted = await cipher.encrypt(text, key);
      final bytes = base64Decode(
        encrypted.substring(HistoryCipher.prefix.length),
      );
      bytes[20] ^= 1;
      final tampered = '${HistoryCipher.prefix}${base64Encode(bytes)}';

      await expectLater(
        cipher.decrypt(tampered, key),
        throwsA(isA<HistoryCipherException>()),
      );
    });

    test('rejects values that are not encrypted or damaged', () async {
      for (final value in [
        '[]',
        '${HistoryCipher.prefix}not base64!',
        '${HistoryCipher.prefix}AAAA',
      ]) {
        await expectLater(
          cipher.decrypt(value, key),
          throwsA(isA<HistoryCipherException>()),
        );
      }
    });

    test('rejects keys of the wrong length', () async {
      expect(() => cipher.encrypt(text, [1, 2, 3]), throwsArgumentError);
      expect(() => cipher.decrypt('x', [1, 2, 3]), throwsArgumentError);
    });

    test('encrypts large values in the background', () async {
      const background = HistoryCipher(isolateThreshold: 16);
      final large = text * 100;

      final encrypted = await background.encrypt(large, key);

      expect(await background.decrypt(encrypted, key), large);
      expect(await cipher.decrypt(encrypted, key), large);
      await expectLater(
        background.decrypt(encrypted, otherKey),
        throwsA(isA<HistoryCipherException>()),
      );
    });

    test('describes its exception', () {
      expect(
        const HistoryCipherException().toString(),
        'HistoryCipherException: History could not be decrypted',
      );
    });
  });
}
