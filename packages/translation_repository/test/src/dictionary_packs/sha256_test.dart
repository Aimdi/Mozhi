import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('Sha256', () {
    test('matches the FIPS 180-4 test vectors', () {
      expect(
        Sha256.of(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        Sha256.of(ascii.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        Sha256.of(
          ascii.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        Sha256.of(List.filled(1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('gives the same digest for any chunking', () {
      final data = List.generate(1000, (index) => index & 0xff);
      final whole = Sha256.of(data);
      for (final size in [1, 3, 55, 56, 63, 64, 65, 200]) {
        final hash = Sha256();
        for (var start = 0; start < data.length; start += size) {
          hash.add(
            data.sublist(
              start,
              start + size > data.length ? data.length : start + size,
            ),
          );
        }
        expect(hash.close(), whole, reason: 'chunks of $size');
      }
    });

    test('closes once', () {
      final hash = Sha256()..add(ascii.encode('abc'));
      final digest = hash.close();
      expect(hash.close(), digest);
      expect(() => hash.add(const [1]), throwsStateError);
    });
  });
}
