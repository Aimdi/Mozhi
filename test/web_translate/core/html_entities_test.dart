import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/html_entities.dart';

void main() {
  group('decodeHtmlEntities', () {
    test('returns the input unchanged when there is no ampersand', () {
      const text = 'plain text';
      expect(identical(decodeHtmlEntities(text), text), isTrue);
    });

    test('decodes markup-significant named references', () {
      expect(
        decodeHtmlEntities('&lt;p&gt; &amp; &quot;x&quot; &apos;y&apos;'),
        '<p> & "x" \'y\'',
      );
    });

    test('decodes Latin-1, typographic and Greek names', () {
      expect(decodeHtmlEntities('&nbsp;'), ' ');
      expect(decodeHtmlEntities('&Agrave;&times;&divide;&yuml;'), 'À×÷ÿ');
      expect(decodeHtmlEntities('&ldquo;&rdquo;&hellip;&euro;'), '“”…€');
      expect(decodeHtmlEntities('&alpha;&Omega;&rarr;&le;'), 'αΩ→≤');
      expect(decodeHtmlEntities('&lang;&rang;'), '⟨⟩');
      expect(decodeHtmlEntities('&AMP;&COPY;'), '&©');
      expect(decodeHtmlEntities('a&Tab;b&NewLine;c'), 'a\tb\nc');
    });

    test('decodes decimal and hexadecimal references', () {
      expect(decodeHtmlEntities('&#65;&#x42;&#X43;'), 'ABC');
      expect(decodeHtmlEntities('&#128512;&#x1F600;'), '😀😀');
      expect(decodeHtmlEntities('&#233 no semicolon'), 'é no semicolon');
    });

    test('maps invalid code points to U+FFFD and C1 through cp1252', () {
      expect(decodeHtmlEntities('&#0;'), '�');
      expect(decodeHtmlEntities('&#xD800;'), '�');
      expect(decodeHtmlEntities('&#x110000;'), '�');
      expect(decodeHtmlEntities('&#999999999999;'), '�');
      expect(decodeHtmlEntities('&#150;&#x80;&#x81;'), '–€\u0081');
    });

    test('keeps unknown or incomplete references', () {
      expect(decodeHtmlEntities('AT&T'), 'AT&T');
      expect(
        decodeHtmlEntities('&unknown; &; & &#; &#x;'),
        '&unknown; &; & &#; &#x;',
      );
      expect(decodeHtmlEntities('trailing &'), 'trailing &');
    });

    test('decodes legacy names without a semicolon in text', () {
      expect(decodeHtmlEntities('&copy 2024'), '© 2024');
      expect(decodeHtmlEntities('&amp more'), '& more');
      expect(decodeHtmlEntities('&eacutetude'), 'étude');
      // Not a legacy name: needs the semicolon.
      expect(decodeHtmlEntities('&hellip more'), '&hellip more');
    });

    test('keeps legacy names followed by = or alphanumerics in attributes', () {
      expect(
        decodeHtmlEntities('?a=1&copy=2&amp;b', inAttribute: true),
        '?a=1&copy=2&b',
      );
      expect(decodeHtmlEntities('x&copyz', inAttribute: true), 'x&copyz');
      expect(decodeHtmlEntities('x&copy z', inAttribute: true), 'x© z');
      expect(decodeHtmlEntities('x&copy;z', inAttribute: true), 'x©z');
    });

    test('exposes the named reference table', () {
      expect(htmlNamedEntities['nbsp'], ' ');
      expect(htmlNamedEntities['trade'], '™');
    });
  });
}
