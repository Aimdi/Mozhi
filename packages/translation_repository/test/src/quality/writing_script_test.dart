import 'package:test/test.dart';
import 'package:translation_repository/src/quality/writing_script.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(WritingScript, () {
    test('classifies letters', () {
      expect(WritingScript.of('a'.runes.first), WritingScript.latin);
      expect(WritingScript.of('ß'.runes.first), WritingScript.latin);
      expect(WritingScript.of('Я'.runes.first), WritingScript.cyrillic);
      expect(WritingScript.of('あ'.runes.first), WritingScript.kana);
      expect(WritingScript.of('漢'.runes.first), WritingScript.han);
      expect(WritingScript.of('한'.runes.first), WritingScript.hangul);
      expect(WritingScript.of('ع'.runes.first), WritingScript.arabic);
      expect(WritingScript.of('𠀀'.runes.first), WritingScript.han);
      expect(WritingScript.of('ᐁ'.runes.first), WritingScript.other);
    });

    test('counts letters only and finds the dominant script', () {
      expect(WritingScript.count('Hi, Мир 123!'), {
        WritingScript.latin: 2,
        WritingScript.cyrillic: 3,
      });
      expect(WritingScript.dominant('Hi, Мир'), WritingScript.cyrillic);
      expect(WritingScript.dominant('123 !?'), isNull);
    });

    test('the scripts of a language', () {
      Set<WritingScript>? of(String code) =>
          WritingScript.expectedFor(Language(code: code, name: code));
      expect(of('ja'), {WritingScript.kana, WritingScript.han});
      expect(of('ko'), {WritingScript.hangul, WritingScript.han});
      expect(of('zh-TW'), {WritingScript.han});
      expect(of('yue'), {WritingScript.han});
      expect(of('ru'), {WritingScript.cyrillic});
      expect(of('de'), {WritingScript.latin});
      expect(of('sr-Latn'), {WritingScript.latin});
      expect(of('uz-Cyrl'), {WritingScript.cyrillic});
      expect(of('hi'), {WritingScript.devanagari});
      expect(of('ar-EG'), {WritingScript.arabic});
      expect(of('zz'), isNull);
      expect(WritingScript.expectedFor(Language.auto), isNull);
      expect(
        WritingScript.expectedFor(const Language.custom('Pirate')),
        isNull,
      );
    });
  });
}
