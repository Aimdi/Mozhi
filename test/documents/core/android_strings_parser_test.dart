// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/android_strings_parser.dart';
import 'package:xml/xml.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseAndroidStrings', () {
    const strings = r'''
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
    <!-- App name: not translated -->
    <string name="app_name" translatable="false">Mozhi</string>
    <string name="hello">Hello, <xliff:g id="name" example="Bob">%1$s</xliff:g>!</string>
    <string name="apostrophe">Don\'t panic</string>
    <string name="quoted">"It's   fine"</string>
    <string name="styled">This is <b>very</b> important</string>
    <string name="lines">First line\nSecond line</string>
    <string name="ref">@string/hello</string>
    <string name="key">dark_mode</string>
    <color name="accent">#FF0000</color>
    <string-array name="planets">
        <item>Mercury</item>
        <item>@string/app_name</item>
    </string-array>
    <plurals name="songs">
        <item quantity="one">%d song found</item>
        <item quantity="other">%d songs found</item>
    </plurals>
    <string name="cdata"><![CDATA[<b>Bold</b> text]]></string>
    <string name="amp">Tom &amp; Jerry</string>
    <string name="wrapped">
        A long text
        on two lines
    </string>
</resources>
''';

    test('round-trips and finds the translatable values', () {
      final document = parseAndroidStrings(strings);
      expect(document.format, DocumentFormat.androidStrings);
      expectRoundTrip(document, strings);
      expect(texts(document), [
        'Hello, ⟨1⟩!',
        "Don't panic",
        "It's   fine",
        'This is ⟨1⟩very⟨2⟩ important',
        'First line⟨1⟩Second line',
        'Mercury',
        '⟨1⟩ song found',
        '⟨1⟩ songs found',
        '⟨1⟩Bold⟨2⟩ text',
        'Tom & Jerry',
        'A long text on two lines',
      ]);
      expect(document.segments[6].label, 'songs:one');
      expect(document.segments[5].label, 'planets[0]');
    });

    test('escapes translations for Android', () {
      final document = parseAndroidStrings(strings);
      final output = document.render([
        'Hallo, ⟨1⟩!',
        "N'ayez pas peur",
        "C'est \"bien\"",
        'Das ist ⟨1⟩sehr⟨2⟩ wichtig',
        'Erste Zeile⟨1⟩Zweite Zeile',
        '@Merkur',
        '⟨1⟩ Lied gefunden (100%)',
        '⟨1⟩ Lieder gefunden',
        '⟨1⟩Fett⟨2⟩ Text & mehr',
        'Tom & Jerry <3',
        'Ein langer Text',
      ]);
      expect(
        output,
        contains(r'>Hallo, <xliff:g id="name" example="Bob">%1$s'),
      );
      expect(output, contains(r'''name="apostrophe">N\'ayez pas peur<'''));
      expect(output, contains(r'''name="quoted">"C'est \"bien\""<'''));
      expect(output, contains('Das ist <b>sehr</b> wichtig'));
      expect(output, contains(r'Erste Zeile\nZweite Zeile'));
      expect(output, contains(r'<item>\@Merkur</item>'));
      expect(output, contains('%d Lied gefunden (100%%)'));
      expect(output, contains('<![CDATA[<b>Fett</b> Text & mehr]]>'));
      expect(output, contains('Tom &amp; Jerry &lt;3'));
      expect(
        output,
        contains('name="wrapped">\n        Ein langer Text\n    </string>'),
      );
      expect(output, contains('translatable="false">Mozhi<'));
      expect(XmlDocument.parse(output), isNotNull);
    });

    test('refuses other XML', () {
      expect(
        () => parseAndroidStrings('<manifest/>'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parseAndroidStrings('<resources><string>x</resources>'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parseAndroidStrings(
          '<!DOCTYPE r [<!ENTITY a "b">]><resources>&a;</resources>',
        ),
        throwsA(isA<DocumentParseException>()),
      );
    });
  });

  group('parseAndroidStrings (more)', () {
    test('handles escapes, comments and odd values', () {
      const text =
          '<?xml version="1.0" encoding="iso-8859-1"?>\r\n'
          '<resources>\r\n'
          '  <item type="string" name="extra">Extra text</item>\r\n'
          '  <item type="id" name="some_id"/>\r\n'
          '  <string name="empty"/>\r\n'
          '  <string name="unicode">Caf\\u00e9\\u0020ok \\a</string>\r\n'
          '  <string name="note">Look <!-- hint --> here</string>\r\n'
          '  <string name="mixed">Text <![CDATA[<i>raw</i>]]> more</string>\r\n'
          '  <string name="plain" formatted="false">%d of %d at 5%</string>\r\n'
          '  <string-array name="sizes" translatable="false"><item>Big</item>'
          '</string-array>\r\n'
          '  <string-array name="other"><eat-comment/><item>Small</item>'
          '</string-array>\r\n'
          '  <string name="mid">Say "hi" now</string>\r\n'
          '</resources>\r\n';
      final document = parseAndroidStrings(text);
      expectRoundTrip(document, text);
      expect(texts(document), [
        'Extra text',
        'Café⟨1⟩ok ⟨2⟩',
        'Look ⟨1⟩ here',
        'Text ⟨1⟩ more',
        '⟨1⟩ of ⟨2⟩ at 5%',
        'Small',
        'Say ⟨1⟩hi⟨2⟩ now',
      ]);
      final output = document.render([
        'Zusatz\\Text\tmit > Zeichen',
        'Café⟨1⟩gut ⟨2⟩',
        'Schau ⟨1⟩ hier',
        'Text ⟨1⟩ mehr\nZeile',
        '⟨1⟩ von ⟨2⟩ bei 5%',
        'Klein',
        'Sag ⟨1⟩hallo⟨2⟩ jetzt',
      ]);
      expect(output, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(
        output,
        contains(r'name="extra">Zusatz\\Text\tmit &gt; Zeichen</item>'),
      );
      expect(output, contains(r'name="unicode">Café\u0020gut \a</string>'));
      expect(output, contains('name="note">Schau <!-- hint --> hier<'));
      expect(
        output,
        contains(r'name="mixed">Text <![CDATA[<i>raw</i>]]> mehr\nZeile<'),
      );
      expect(output, contains('formatted="false">%d von %d bei 5%</string>'));
      expect(output, contains('<eat-comment/><item>Klein</item>'));
      expect(output, contains('name="mid">Sag "hallo" jetzt</string>'));
      expect(output, contains('<item>Big</item>'));
    });

    test('keeps quoted values with escaped quotes and lone quotes', () {
      const text =
          '<resources>'
          r'<string name="a">"He said \"no\""</string>'
          '<string name="b">"</string>'
          '</resources>';
      final document = parseAndroidStrings(text);
      expectRoundTrip(document, text);
      expect(texts(document), ['He said "no"']);
      expect(
        document.render(["Il a dit \"non\" à l'instant"]),
        contains(
          r'''<string name="a">"Il a dit \"non\" à l'instant"</string>''',
        ),
      );
    });
  });

  group('Android plurals placeholder safety', () {
    const missingPlaceholder = r'''
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
    <plurals name="files">
        <item quantity="one">One file</item>
        <item quantity="other">%d files</item>
    </plurals>
    <plurals name="braces">
        <item quantity="one">One item</item>
        <item quantity="other">{0} items</item>
    </plurals>
    <plurals name="xliff_arg">
        <item quantity="one">One song</item>
        <item quantity="other"><xliff:g id="count">%1$d</xliff:g> songs</item>
    </plurals>
    <plurals name="literal_percent">
        <item quantity="one">One item (100%%)</item>
        <item quantity="other">Many items (100%%)</item>
    </plurals>
</resources>
''';

    test(
      'maps one from other when target one covers >1 and lacks placeholders',
      () {
        for (final lang in ['ru', 'uk', 'sr', 'fr', 'is']) {
          final doc = parseAndroidStrings(
            missingPlaceholder,
            targetLanguage: lang,
          );
          expectRoundTrip(doc, missingPlaceholder);
          final out = doc.render([
            '[one-file]',
            '[other-files] ⟨1⟩',
            '[one-item]',
            '[other-items] ⟨1⟩',
            '[one-song]',
            '[other-songs] ⟨1⟩',
            '[one-pct] 100⟨1⟩',
            '[other-pct] 100⟨1⟩',
          ]);
          expect(
            out,
            contains('<item quantity="one">[other-files] %d</item>'),
            reason: '$lang files',
          );
          expect(
            out,
            contains('<item quantity="one">[other-items] {0}</item>'),
            reason: '$lang braces',
          );
          expect(
            out,
            contains(
              '<item quantity="one">[other-songs] '
              r'<xliff:g id="count">%1$d</xliff:g></item>',
            ),
            reason: '$lang xliff_arg',
          );
          // Literal %% is not a placeholder, so one keeps its own translation.
          expect(
            out,
            contains('<item quantity="one">[one-pct] 100%%</item>'),
            reason: '$lang literal_percent',
          );
          expect(XmlDocument.parse(out), isNotNull);
        }
      },
    );

    test('keeps one when target one covers only 1 (de, pl, ar)', () {
      for (final lang in ['de', 'pl', 'ar']) {
        final doc = parseAndroidStrings(
          missingPlaceholder,
          targetLanguage: lang,
        );
        final out = doc.render([
          '[one-file]',
          '[other-files] ⟨1⟩',
          '[one-item]',
          '[other-items] ⟨1⟩',
          '[one-song]',
          '[other-songs] ⟨1⟩',
          '[one-pct] 100⟨1⟩',
          '[other-pct] 100⟨1⟩',
        ]);
        expect(
          out,
          contains('<item quantity="one">[one-file]</item>'),
          reason: lang,
        );
        expect(
          out,
          contains('<item quantity="one">[one-item]</item>'),
          reason: lang,
        );
        expect(
          out,
          contains('<item quantity="one">[one-song]</item>'),
          reason: lang,
        );
      }
    });

    test(
      'keeps one for Russian when both one and other have the placeholder',
      () {
        const bothHave = '''
<resources>
    <plurals name="files">
        <item quantity="one">%d file</item>
        <item quantity="other">%d files</item>
    </plurals>
</resources>
''';
        final doc = parseAndroidStrings(bothHave, targetLanguage: 'ru');
        final out = doc.render(['⟨1⟩ файл', '⟨1⟩ файлов']);
        expect(out, contains('<item quantity="one">%d файл</item>'));
        expect(out, contains('<item quantity="few">%d файлов</item>'));
        expect(out, contains('<item quantity="many">%d файлов</item>'));
        expect(out, contains('<item quantity="other">%d файлов</item>'));
      },
    );
  });
}
