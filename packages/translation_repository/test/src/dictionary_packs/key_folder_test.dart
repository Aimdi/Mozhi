import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('DictionaryKeyFolder', () {
    final folder = DictionaryKeyFolder(const {
      'C': 'c',
      'É': 'e',
      'é': 'e',
      '\u0301': '',
      'ß': 'ss',
      '’': "'",
      '😀': 'smile',
      'ab': 'ignored',
    });

    test('maps each character through its table', () {
      expect(folder.fold('Café'), 'cafe');
      expect(folder.fold('CAFÉ'), 'cAFe');
      expect(folder.fold('cafe\u0301'), 'cafe');
      expect(folder.fold('Straße'), 'Strasse');
      expect(folder.fold('don’t'), "don't");
      expect(folder.fold('😀!'), 'smile!');
    });

    test('ignores entries that are not one character', () {
      expect(folder.table.containsKey('a'.runes.single), isFalse);
      expect(folder.fold('ab'), 'ab');
    });

    test('collapses spaces and trims them', () {
      expect(folder.fold('  ice \u00a0\t cream\u3000'), 'ice cream');
      expect(DictionaryKeyFolder.collapseSpaces('   '), '');
      expect(DictionaryKeyFolder.collapseSpaces('a\nb'), 'a b');
    });
  });

  group('basicFoldRune', () {
    String fold(String text) => text.runes.map(basicFoldRune).join();

    test('folds case and Latin diacritics', () {
      expect(fold('Café'), 'cafe');
      expect(fold('NAÏVE'), 'naive');
      expect(fold('Ångström'), 'angstrom');
      expect(fold('Việt'), 'viet');
      expect(fold('cafe\u0301'), 'cafe');
      expect(fold('‘quoted’ ʼ'), "'quoted' '");
    });

    test('keeps other scripts', () {
      expect(fold('Чай'), 'чай');
      expect(fold('한국어 家 が'), '한국어 家 が');
    });
  });
}
