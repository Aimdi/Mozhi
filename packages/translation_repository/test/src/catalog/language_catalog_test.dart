import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(LanguageCatalog, () {
    final all = LanguageCatalog.all;

    test('has about 200+ languages', () {
      expect(all.length, greaterThanOrEqualTo(200));
    });

    test('is sorted by English name', () {
      for (var i = 1; i < all.length; i++) {
        final previous = all[i - 1].name.toLowerCase();
        final current = all[i].name.toLowerCase();
        expect(
          previous.compareTo(current),
          lessThan(0),
          reason: '${all[i - 1].name} should sort before ${all[i].name}',
        );
      }
    });

    test('codes and names are unique; entries are complete', () {
      final codes = <String>{};
      final names = <String>{};
      for (final language in all) {
        expect(
          codes.add(language.code.toLowerCase()),
          isTrue,
          reason: 'duplicate code ${language.code}',
        );
        expect(
          names.add(language.name.toLowerCase()),
          isTrue,
          reason: 'duplicate name ${language.name}',
        );
        expect(language.name.trim(), language.name);
        expect(language.nativeName, isNotNull, reason: language.code);
        expect(language.nativeName!.trim(), isNotEmpty);
        expect(language.isCustom, isFalse);
        expect(
          RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(language.code),
          isTrue,
          reason: language.code,
        );
      }
    });

    test('never contains auto', () {
      expect(all.where((l) => l.isAuto), isEmpty);
      expect(LanguageCatalog.byCode('auto'), isNull);
    });

    test('codes are already normalised', () {
      for (final language in all) {
        expect(
          LanguageMatcher.normalize(language.code),
          language.code,
          reason: language.code,
        );
      }
    });

    test('contains every Google Translate language', () {
      const google = [
        'af', 'sq', 'am', 'ar', 'hy', 'as', 'ay', 'az', 'bm', 'eu', 'be', //
        'bn', 'bho', 'bs', 'bg', 'ca', 'ceb', 'ny', 'zh-CN', 'zh-TW', 'co',
        'hr', 'cs', 'da', 'dv', 'doi', 'nl', 'en', 'eo', 'et', 'ee', 'tl',
        'fi', 'fr', 'fy', 'gl', 'ka', 'de', 'el', 'gn', 'gu', 'ht', 'ha',
        'haw', 'he', 'hi', 'hmn', 'hu', 'is', 'ig', 'ilo', 'id', 'ga', 'it',
        'ja', 'jv', 'kn', 'kk', 'km', 'rw', 'gom', 'ko', 'kri', 'ku', 'ckb',
        'ky', 'lo', 'la', 'lv', 'ln', 'lt', 'lg', 'lb', 'mk', 'mai', 'mg',
        'ms', 'ml', 'mt', 'mi', 'mr', 'mni-Mtei', 'lus', 'mn', 'my', 'ne',
        'no', 'or', 'om', 'ps', 'fa', 'pl', 'pt', 'pa', 'qu', 'ro', 'ru',
        'sm', 'sa', 'gd', 'nso', 'sr', 'st', 'sn', 'sd', 'si', 'sk', 'sl',
        'so', 'es', 'su', 'sw', 'sv', 'tg', 'ta', 'tt', 'te', 'th', 'ti',
        'ts', 'tr', 'tk', 'ak', 'uk', 'ur', 'ug', 'uz', 'vi', 'cy', 'xh',
        'yi', 'yo', 'zu',
        // 2024 additions (selection).
        'ab', 'ace', 'ach', 'aa', 'alz', 'av', 'awa', 'ban', 'bal', 'ba',
        'bci', 'btx', 'bts', 'bbc', 'bem', 'bew', 'bik', 'br', 'bua', 'yue',
        'ch', 'ce', 'chk', 'cv', 'crh', 'crs', 'fa-AF', 'din', 'dyu', 'dz',
        'fo', 'fj', 'fon', 'fr-CA', 'fur', 'ff', 'gaa', 'cnh', 'hil', 'hrx',
        'iba', 'jam', 'kac', 'kl', 'kr', 'pam', 'kha', 'cgg', 'kg', 'ktu',
        'trp', 'kv', 'ltg', 'lij', 'li', 'lmo', 'luo', 'mad', 'mak',
        'ms-Arab', 'mam', 'gv', 'mh', 'mwr', 'mfe', 'chm', 'min', 'nhe',
        'ndc-ZW', 'nr', 'new', 'nqo', 'nus', 'oc', 'os', 'pag', 'pap',
        'pa-Arab', 'kek', 'rom', 'rn', 'se', 'sg', 'sat', 'scn', 'shn',
        'szl', 'sus', 'ss', 'ty', 'ber-Latn', 'ber', 'tet', 'bo', 'tiv',
        'tpi', 'to', 'tn', 'tcy', 'tum', 'tyv', 'udm', 've', 'vec', 'war',
        'wo', 'sah', 'yua', 'zap', 'pt-PT',
      ];
      for (final code in google) {
        expect(LanguageCatalog.byCode(code), isNotNull, reason: code);
        expect(LanguageCatalog.byCode(code)!.code, code);
      }
    });

    test('contains the documented regional variants and extras', () {
      const variants = [
        'pt-BR', 'pt-PT', 'zh-CN', 'zh-TW', 'yue', 'es-419', 'fr-CA', //
        'en-GB', 'en-US', 'sr-Latn', 'ckb', 'ar-EG', 'ar-MA', 'ar-LB',
        'la', 'eo', 'sa', 'tpi', 'grc', 'tok', 'lzh',
      ];
      for (final code in variants) {
        expect(LanguageCatalog.byCode(code), isNotNull, reason: code);
      }
      expect(all.where((l) => l.code.startsWith('ar-')).length, greaterThan(4));
    });

    test('native names use the native script', () {
      const expected = {
        'ja': '日本語',
        'zh-CN': '简体中文',
        'zh-TW': '繁體中文',
        'yue': '粵語',
        'ko': '한국어',
        'ru': 'Русский',
        'ar': 'العربية',
        'he': 'עברית',
        'hi': 'हिन्दी',
        'ta': 'தமிழ்',
        'th': 'ไทย',
        'el': 'Ελληνικά',
        'am': 'አማርኛ',
        'ka': 'ქართული',
        'hy': 'Հայերեն',
        'sr': 'Српски',
        'sr-Latn': 'Srpski',
        'de': 'Deutsch',
        'fr': 'Français',
        'es': 'Español',
        'sa': 'संस्कृतम्',
        'mni-Mtei': 'ꯃꯤꯇꯩꯂꯣꯟ',
        'pa': 'ਪੰਜਾਬੀ',
        'pa-Arab': 'پنجابی',
      };
      expected.forEach((code, native) {
        expect(LanguageCatalog.byCode(code)?.nativeName, native, reason: code);
      });
    });

    group('byCode', () {
      test('is case-insensitive and accepts underscores', () {
        expect(LanguageCatalog.byCode('ZH_tw')?.code, 'zh-TW');
        expect(LanguageCatalog.byCode('pt_br')?.code, 'pt-BR');
        expect(LanguageCatalog.byCode(' EN ')?.code, 'en');
        expect(LanguageCatalog.byCode('SR-LATN')?.code, 'sr-Latn');
      });

      test('resolves legacy and regional codes', () {
        expect(LanguageCatalog.byCode('iw')?.code, 'he');
        expect(LanguageCatalog.byCode('jw')?.code, 'jv');
        expect(LanguageCatalog.byCode('zh')?.code, 'zh-CN');
        expect(LanguageCatalog.byCode('zh-Hant')?.code, 'zh-TW');
        expect(LanguageCatalog.byCode('fr-FR')?.code, 'fr');
        expect(LanguageCatalog.byCode('nb')?.code, 'no');
        expect(LanguageCatalog.byCode('fil')?.code, 'tl');
      });

      test('returns null for unknown or empty codes', () {
        expect(LanguageCatalog.byCode('xx'), isNull);
        expect(LanguageCatalog.byCode(''), isNull);
        expect(LanguageCatalog.byCode('  '), isNull);
      });

      test('finds every catalogue entry', () {
        for (final language in all) {
          expect(LanguageCatalog.byCode(language.code), same(language));
        }
      });
    });

    group('byName', () {
      test('finds every entry by its English name', () {
        for (final language in all) {
          expect(LanguageCatalog.byName(language.name), same(language));
        }
      });

      test('ignores case and punctuation', () {
        expect(LanguageCatalog.byName('japanese')?.code, 'ja');
        expect(LanguageCatalog.byName('Chinese Simplified')?.code, 'zh-CN');
        expect(LanguageCatalog.byName('kiche')?.code, 'quc');
        expect(LanguageCatalog.byName('Klingonese'), isNull);
        expect(LanguageCatalog.byName(''), isNull);
      });
    });

    test('nameOf', () {
      expect(LanguageCatalog.nameOf('de'), 'German');
      expect(LanguageCatalog.nameOf('iw'), 'Hebrew');
      expect(LanguageCatalog.nameOf('zz-Unknown'), 'zz-Unknown');
    });

    test('customSuggestions', () {
      expect(LanguageCatalog.customSuggestions, contains('LinkedIn Speak'));
      expect(LanguageCatalog.customSuggestions, contains('Pirate speak'));
    });
  });
}
