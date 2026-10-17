import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/whisper_speech.dart';

void main() {
  group('whisperLanguages', () {
    test('has the 99 languages of the tiny and base models', () {
      expect(whisperLanguages, hasLength(99));
      expect(whisperLanguages.keys.first, 'en');
      expect(whisperLanguages.keys.last, 'su');
      expect(whisperLanguages, isNot(contains('yue')));
    });

    test("matches whisper.cpp's language table, in token order", () {
      final source = File('native/third_party/whisper.cpp/src/whisper.cpp');
      if (!source.existsSync()) {
        markTestSkipped('whisper.cpp is not checked out');
        return;
      }
      final codes = [
        for (final match in RegExp(
          r'\{ "([a-z]+)", +\{ *(\d+), +"[a-z ]+", *\} *\}',
        ).allMatches(source.readAsStringSync()))
          (match.group(1)!, int.parse(match.group(2)!)),
      ];
      final ids = {for (final (code, id) in codes) code: id};
      expect(
        [
          for (final (index, code) in whisperLanguages.keys.indexed)
            (code, ids[code] == index),
        ].where((entry) => !entry.$2),
        isEmpty,
      );
    });
  });

  group('whisperLanguageFor', () {
    test('detects for null, empty, auto and unknown codes', () {
      for (final code in [null, '', '  ', 'auto', 'AUTO', 'yue', 'qu', '-']) {
        expect(whisperLanguageFor(code), isNull, reason: '$code');
      }
    });

    test('keeps the primary subtag', () {
      expect(whisperLanguageFor('en'), 'en');
      expect(whisperLanguageFor('pt-BR'), 'pt');
      expect(whisperLanguageFor('zh-TW'), 'zh');
      expect(whisperLanguageFor('zh_Hans_CN'), 'zh');
      expect(whisperLanguageFor('sr-Latn'), 'sr');
      expect(whisperLanguageFor('pa-Arab'), 'pa');
      expect(whisperLanguageFor('fa-AF'), 'fa');
      expect(whisperLanguageFor(' DE '), 'de');
      expect(whisperLanguageFor('haw'), 'haw');
    });

    test('applies aliases', () {
      expect(whisperLanguageFor('iw'), 'he');
      expect(whisperLanguageFor('in'), 'id');
      expect(whisperLanguageFor('ji'), 'yi');
      expect(whisperLanguageFor('jv'), 'jw');
      expect(whisperLanguageFor('jw'), 'jw');
      expect(whisperLanguageFor('fil'), 'tl');
      expect(whisperLanguageFor('nb'), 'no');
      expect(whisperLanguageFor('nob'), 'no');
      expect(whisperLanguageFor('nno'), 'nn');
      expect(whisperLanguageFor('cmn-Hans'), 'zh');
    });
  });

  group('languageForWhisper', () {
    test('maps Javanese back and keeps the others', () {
      expect(languageForWhisper('jw'), 'jv');
      expect(languageForWhisper('he'), 'he');
      expect(languageForWhisper('haw'), 'haw');
      expect(languageForWhisper('xx'), isNull);
      expect(languageForWhisper(null), isNull);
    });

    test('round-trips every Whisper language', () {
      for (final code in whisperLanguages.keys) {
        expect(whisperLanguageFor(languageForWhisper(code)), code);
      }
    });
  });
}
