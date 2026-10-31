import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/nfc_table.dart';
import 'package:mozhi/backup/data/passphrase_nfc.dart';

const _script = 'tool/passphrase_nfc.py';

Future<String> _python(List<String> arguments, {String? input}) async {
  final process = await Process.start('python3', [_script, ...arguments]);
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  expect(code, 0, reason: await errors);
  return await output;
}

void main() {
  group('passphraseNfc', () {
    test('the table matches a fresh generation', () async {
      final generated = await _python(['--stdout']);
      final committed = File('lib/backup/data/nfc_table.dart')
          .readAsStringSync();
      expect(
        committed == generated,
        isTrue,
        reason: 'run python3 $_script to regenerate the table',
      );
    });

    test('leaves ASCII as it is', () {
      const text = 'correct horse battery staple 42!';
      expect(identical(passphraseNfc(text), text), isTrue);
      expect(passphraseNfc(''), '');
    });

    test('composes a letter and its combining mark', () {
      expect(passphraseNfc('café'), 'café');
      expect(passphraseNfc('café'), 'café');
      expect(passphraseNfc('Å'), 'Å');
    });

    test("composes Vietnamese's stacked diacritics in any order", () {
      const viet = 'Việt';
      expect(passphraseNfc('Việt'), viet);
      expect(passphraseNfc('Việt'), viet);
      expect(passphraseNfc('Việt'), viet);
      expect(passphraseNfc('Việt'), viet);
    });

    test('composes Greek and Cyrillic', () {
      expect(passphraseNfc('ᾄ'), 'ᾄ');
      expect(passphraseNfc('й'), 'й');
      expect(passphraseNfc('ё'), 'ё');
    });

    test('maps singletons and composes Hangul and kana', () {
      expect(passphraseNfc('Å'), 'Å');
      expect(passphraseNfc('ά'), 'ά');
      expect(passphraseNfc('한'), '한');
      expect(passphraseNfc('하'), '하');
      expect(passphraseNfc('한'), '한');
      expect(passphraseNfc('が'), 'が');
      expect(passphraseNfc('≠'), '≠');
    });

    test('keeps a blocked mark apart', () {
      // The dot below would compose with "a", but the grave (class 230)
      // came first and stays; the dot (220) moves before it.
      expect(passphraseNfc('ạ̀'), 'ạ̀');
      // A mark of the same class as the one before is blocked.
      expect(passphraseNfc('á́'), 'á́');
      // A mark at the start has no starter.
      expect(passphraseNfc('́a'), '́a');
    });

    test('leaves other scripts and emoji as they are', () {
      const text = 'क़ \u{1F600} 中';
      expect(passphraseNfc(text), text);
    });

    test("agrees with Python's NFC on generated strings", () async {
      final random = Random(8);
      final starters = <int>[
        for (var c = 0x41; c <= 0x5A; c++) ...[c, c + 0x20],
        for (var c = 0x391; c <= 0x3C9; c++) c,
        for (var c = 0x410; c <= 0x44F; c++) c,
        0x3D, 0x3C, 0x3E, 0x2208, 0x2190, // operators with a slash
        0x304B, 0x30AB, 0x3046, 0x309D, // kana
        0x1100, 0x1112, 0x1161, 0x1175, 0x11A8, 0xAC00, 0xD55C, // Hangul
        ...nfcDecompositions.keys,
      ];
      final marks = nfcCombiningClasses.keys.toList();
      // Mostly marks, so that their order and blocking are exercised.
      int next() => random.nextInt(3) == 0
          ? starters[random.nextInt(starters.length)]
          : marks[random.nextInt(marks.length)];
      final strings = [
        for (var i = 0; i < 4000; i++)
          String.fromCharCodes(
            List.generate(1 + random.nextInt(7), (_) => next()),
          ),
      ];
      final expected = (jsonDecode(
        await _python(['--normalize'], input: jsonEncode(strings)),
      ) as List<Object?>).cast<String>();
      final mismatches = [
        for (var i = 0; i < strings.length; i++)
          if (passphraseNfc(strings[i]) != expected[i])
            '${_codes(strings[i])} -> ${_codes(passphraseNfc(strings[i]))}, '
                    'Python ${_codes(expected[i])}'
                .trim(),
      ];
      expect(mismatches, isEmpty);
    });
  });
}

String _codes(String text) =>
    text.runes.map((rune) => rune.toRadixString(16)).join(' ');
