import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';

void main() {
  final code = PairingCode(
    address: const [192, 168, 1, 20],
    port: 41234,
    secret: const [1, 2, 3, 4, 5, 6, 7, 250],
  );

  group('PairingCode', () {
    test('writes 24 characters in groups of four', () {
      expect(code.text, matches(RegExp(r'^([0-9A-Z]{4}-){5}[0-9A-Z]{4}$')));
      expect(code.host, '192.168.1.20');
      expect(code.toString(), 'PairingCode(192.168.1.20:41234)');
    });

    test('reads its text back, in any case and spacing', () {
      expect(PairingCode.tryParse(code.text), code);
      expect(PairingCode.tryParse(code.text.toLowerCase()), code);
      expect(PairingCode.tryParse(' ${code.text.replaceAll('-', ' ')} '), code);
      expect(PairingCode.tryParse(code.text.replaceAll('-', '')), code);
    });

    test('reads O, I and L as the digits they look like', () {
      final text = code.text;
      final lookalikes = text
          .replaceAll('0', 'O')
          .replaceAll('1', 'l')
          .toLowerCase();
      expect(PairingCode.tryParse(lookalikes), code);
    });

    test('reads its link and the app location', () {
      expect(code.link, startsWith('mozhi://pair?code='));
      expect(code.link, isNot(contains('-')));
      expect(PairingCode.tryParse(code.link), code);
      expect(PairingCode.tryParse('MOZHI://PAIR?code=${code.text}'), code);
      expect(PairingCode.tryParse('/pair?code=${code.text}'), code);
    });

    test('refuses links of other hosts and schemes', () {
      final plain = code.link.split('=').last;
      expect(PairingCode.tryParse('mozhi://translate?code=$plain'), isNull);
      expect(PairingCode.tryParse('https://pair?code=$plain'), isNull);
      expect(PairingCode.tryParse('/translate?code=$plain'), isNull);
    });

    test('catches a mistyped or swapped character', () {
      final plain = code.link.split('=').last;
      const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
      for (var i = 0; i < plain.length; i++) {
        final other = alphabet[(alphabet.indexOf(plain[i]) + 7) % 32];
        final typo = plain.replaceRange(i, i + 1, other);
        expect(PairingCode.tryParse(typo), isNull, reason: 'typo at $i');
      }
      for (var i = 0; i + 1 < plain.length; i++) {
        if (plain[i] == plain[i + 1]) continue;
        final swapped =
            plain.substring(0, i) +
            plain[i + 1] +
            plain[i] +
            plain.substring(i + 2);
        expect(PairingCode.tryParse(swapped), isNull, reason: 'swap at $i');
      }
    });

    test('refuses other lengths, characters and an empty port', () {
      final plain = code.link.split('=').last;
      expect(PairingCode.tryParse(''), isNull);
      expect(PairingCode.tryParse(plain.substring(1)), isNull);
      expect(PairingCode.tryParse('${plain}0'), isNull);
      expect(PairingCode.tryParse(plain.replaceRange(3, 4, 'U')), isNull);
      expect(PairingCode.tryParse(plain.replaceRange(3, 4, '!')), isNull);
      // A code for port 0 (which cannot be built) is not one.
      expect(
        PairingCode.tryParse(
          _encode([10, 0, 0, 1, 0, 0, ...List.filled(8, 0)]),
        ),
        isNull,
      );
      expect(
        PairingCode.tryParse(_encode([10, 0, 0, 1, 0, 9, ...List.filled(8, 0)]))
            ?.port,
        9,
      );
    });

    test('generates a fresh secret each time', () {
      final random = Random(1);
      final a = PairingCode.generate(
        address: const [10, 0, 0, 2],
        port: 5000,
        random: random,
      );
      final b = PairingCode.generate(
        address: const [10, 0, 0, 2],
        port: 5000,
        random: random,
      );
      expect(a.secret, hasLength(PairingCode.secretLength));
      expect(a, isNot(b));
      expect(PairingCode.tryParse(a.text), a);
      expect(
        PairingCode.generate(address: const [10, 0, 0, 2], port: 5000).secret,
        hasLength(8),
      );
    });

    test('checks its parts', () {
      expect(
        () => PairingCode(address: const [1, 2, 3], port: 1, secret: const [0]),
        throwsArgumentError,
      );
      expect(
        () => PairingCode(
          address: const [1, 2, 3, 4],
          port: 0,
          secret: List.filled(8, 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => PairingCode(
          address: const [1, 2, 3, 4],
          port: 70000,
          secret: List.filled(8, 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => PairingCode(
          address: const [1, 2, 3, 4],
          port: 80,
          secret: const [1],
        ),
        throwsArgumentError,
      );
    });
  });
}

/// The code text of [bytes], written like [PairingCode.text] does.
String _encode(List<int> bytes) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final values = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8 | byte) & 0xffff;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      values.add(buffer >> bits & 31);
    }
  }
  if (bits > 0) values.add(buffer << (5 - bits) & 31);
  var sum = 0;
  for (final (index, value) in values.indexed) {
    sum += (index + 1) * value;
  }
  return [
    for (final value in [...values, sum % 31]) alphabet[value],
  ].join();
}
