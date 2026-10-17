import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/translate/widgets/language_search.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('foldForSearch', () {
    test('lower-cases and removes diacritics', () {
      expect(foldForSearch('Français'), 'francais');
      expect(foldForSearch('Español'), 'espanol');
      expect(foldForSearch('Português'), 'portugues');
      expect(foldForSearch('Tiếng Việt'), 'tieng viet');
      expect(foldForSearch('Čeština'), 'cestina');
      expect(foldForSearch('Türkçe'), 'turkce');
      expect(foldForSearch('Română'), 'romana');
    });

    test('spells out letters without a plain twin', () {
      expect(foldForSearch('Norsk bokmål'), 'norsk bokmal');
      expect(foldForSearch('Føroyskt'), 'foroyskt');
      expect(foldForSearch('Straße'), 'strasse');
      expect(foldForSearch('Polski Łódź'), 'polski lodz');
      expect(foldForSearch('Æsir'), 'aesir');
      expect(foldForSearch('Œuvre'), 'oeuvre');
      expect(foldForSearch('Íslenska þ'), 'islenska th');
    });

    test('drops combining marks', () {
      // "c" followed by a combining cedilla.
      expect(foldForSearch('Français'), 'francais');
      expect(foldForSearch('İzmir'), 'izmir');
    });

    test('folds Greek and Cyrillic accents, keeps other scripts', () {
      expect(foldForSearch('Ελληνικά'), 'ελληνικα');
      expect(foldForSearch('Ёлка'), 'елка');
      expect(foldForSearch('日本語'), '日本語');
      expect(foldForSearch('हिन्दी'), 'हिन्दी');
    });
  });

  group('matchLanguages', () {
    const french = Language(code: 'fr', name: 'French', nativeName: 'Français');
    const spanish = Language(
      code: 'es',
      name: 'Spanish',
      nativeName: 'Español',
    );
    const chinese = Language(
      code: 'zh-CN',
      name: 'Chinese (Simplified)',
      nativeName: '简体中文',
    );
    const frisian = Language(
      code: 'fy',
      name: 'Western Frisian',
      nativeName: 'Frysk',
    );
    const languages = [Language.auto, french, spanish, chinese, frisian];

    test('matches native names without diacritics', () {
      expect(matchLanguages(languages, 'francais'), [french]);
      expect(matchLanguages(languages, 'ESPANOL'), [spanish]);
      expect(matchLanguages(languages, 'Español'), [spanish]);
    });

    test('matches English names, codes and native scripts', () {
      expect(matchLanguages(languages, 'span'), [spanish]);
      // The code first, then names that contain it ("Chinese").
      expect(matchLanguages(languages, 'es').first, spanish);
      expect(matchLanguages(languages, '中文'), [chinese]);
    });

    test('puts prefixes first, then word starts, then the rest', () {
      expect(matchLanguages(languages, 'fr'), [french, frisian]);
      expect(matchLanguages(languages, 'simp'), [chinese]);
      expect(matchLanguages(languages, 'is'), [spanish, frisian]);
      expect(matchLanguages(languages, 'ch'), [chinese, french]);
    });

    test('never matches "Detect language" or an empty query', () {
      expect(matchLanguages(languages, 'detect'), isEmpty);
      expect(matchLanguages(languages, '  '), isEmpty);
    });
  });
}
