// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:mozhi/documents/core/office/sheet_parts.dart';

import 'office_fixtures.dart';

void main() {
  group('LanguageTag', () {
    test('parses BCP 47 codes', () {
      final german = LanguageTag.tryParse('de')!;
      expect(german.language, 'de');
      expect(german.script, isNull);
      expect(german.region, isNull);
      expect(german.officeRegion, 'DE');
      expect(german.bcp47, 'de');
      expect(german.culture, 'de-DE');
      expect(german.scriptClass, ScriptClass.western);
      expect(german.toString(), 'LanguageTag(de)');

      final brazil = LanguageTag.tryParse('pt_br')!;
      expect(brazil.bcp47, 'pt-BR');
      expect(brazil.culture, 'pt-BR');

      final traditional = LanguageTag.tryParse('zh-hant-TW')!;
      expect(traditional.script, 'Hant');
      expect(traditional.culture, 'zh-Hant-TW');
      expect(traditional.scriptClass, ScriptClass.asian);

      final serbian = LanguageTag.tryParse('sr-Latn')!;
      expect(serbian.officeRegion, isNull);
      expect(serbian.culture, 'sr-Latn');

      expect(LanguageTag.tryParse('es-419')!.region, '419');
      expect(LanguageTag.tryParse('iw')!.language, 'he');
      expect(LanguageTag.tryParse('he')!.scriptClass, ScriptClass.complex);
      expect(LanguageTag.tryParse('hi')!.scriptClass, ScriptClass.complex);
      expect(LanguageTag.tryParse('az-Arab')!.scriptClass, ScriptClass.complex);
      expect(LanguageTag.tryParse('xx')!.culture, 'xx');
      expect(LanguageTag.tryParse('de-DE-1996-x-private')!.bcp47, 'de-DE');
    });

    test('rejects what is not a language code', () {
      expect(LanguageTag.tryParse(null), isNull);
      expect(LanguageTag.tryParse(''), isNull);
      expect(LanguageTag.tryParse('Pirate speak'), isNull);
      expect(LanguageTag.tryParse('english'), isNull);
    });
  });

  group('ST_Xstring', () {
    test('decodes and encodes escapes', () {
      expect(decodeXstring('a_x000D__x000A_b'), 'a\r\nb');
      expect(decodeXstring('plain'), 'plain');
      expect(encodeXstring('a\rb\u0001c\td\ne'), 'a_x000D_b_x0001_c\td\ne');
      expect(encodeXstring('_x0041_'), '_x005F_x0041_');
      expect(decodeXstring(encodeXstring('_x0041_ and \r')), '_x0041_ and \r');
    });
  });

  group('previews', () {
    test('placeholders are removed', () {
      expect(
        segmentPreview('Read ⟨1⟩this⟨2⟩ and ⟨3⟩ that'),
        'Read this and that',
      );
      expect(
        segmentsPreview(
          const [Segment('One ⟨1⟩two⟨2⟩'), Segment('Three')],
          const ['Eins ⟨1⟩zwei⟨2⟩'],
        ),
        'Eins zwei\n\nThree',
      );
      expect(segmentsPreview(const [Segment('A'), Segment('B')]), 'A\n\nB');
    });
  });

  group('language marks', () {
    test('OpenDocument styles: Asian and complex targets', () {
      final bytes = odf(
        'text',
        '<office:text><text:p>Hello</text:p></office:text>',
        automaticStyles:
            '<style:style style:name="T1" style:family="text">'
            '<style:text-properties style:language-complex="ar" '
            'style:country-complex="EG" style:script-complex="Arab"/>'
            '</style:style><style:style style:name="T2" style:family="text">'
            '<style:text-properties fo:color="#000000"/></style:style>',
      );
      String content(String target) => entryText(
        parsePackagedDocument(
          bytes,
          DocumentFormat.odt,
          targetLanguage: target,
        ).render(['X']),
        'content.xml',
      );
      final hebrew = content('he');
      expect(
        hebrew,
        contains('style:language-complex="he" style:country-complex="IL"/>'),
      );
      expect(hebrew, contains('<style:text-properties fo:color="#000000"/>'));
      expect(
        entryText(
          parsePackagedDocument(
            bytes,
            DocumentFormat.odt,
            targetLanguage: 'zh-Hant',
          ).render(['X']),
          'styles.xml',
        ),
        contains('style:language-asian="zh"/>'),
      );
    });
  });
}
