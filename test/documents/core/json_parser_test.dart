import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseJson', () {
    test('translates string values only, keeping keys and layout', () {
      const text =
          '{\n'
          '  "title": "Hello world",\n'
          '  "count": 3,\n'
          '  "enabled": true,\n'
          '  "nothing": null,\n'
          '  "nested": { "save": "Save",  "items": ["One", "Two", 4] },\n'
          '  "empty": {}, "list": []\n'
          '}\n';
      final document = parseJson(text);
      expect(document.format, DocumentFormat.json);
      expect(texts(document), ['Hello world', 'Save', 'One', 'Two']);
      expect(document.segments.map((s) => s.label), [
        'title',
        'nested.save',
        'nested.items[0]',
        'nested.items[1]',
      ]);
      expectRoundTrip(document, text);
      final output = renderUpper(document);
      expect(output, contains('"title": "HELLO WORLD",\n  "count": 3,'));
      expect(
        output,
        contains('{ "save": "SAVE",  "items": ["ONE", "TWO", 4] }'),
      );
      expect(jsonDecode(output), isA<Map<String, dynamic>>());
    });

    test('keeps ARB metadata and @@locale untouched', () {
      const text = '''
{
  "@@locale": "en",
  "appTitle": "My app",
  "@appTitle": {
    "description": "The title of the application"
  },
  "greeting": "Hello {name}!",
  "@greeting": {
    "placeholders": { "name": { "type": "String", "example": "Bob" } }
  }
}
''';
      final document = parseJson(text);
      expect(texts(document), ['My app', 'Hello ⟨1⟩!']);
      expectRoundTrip(document, text);
      final output = document.render(['Meine App', 'Hallo ⟨1⟩!']);
      final json = jsonDecode(output) as Map<String, dynamic>;
      expect(json['@@locale'], 'en');
      expect(json['appTitle'], 'Meine App');
      expect(json['greeting'], 'Hallo {name}!');
      expect(json['@appTitle'], {
        'description': 'The title of the application',
      });
    });

    test('translates plural variants inside the surrounding sentence', () {
      const text =
          '{"cart": "You have {count, plural, =0{no items} =1{one item} '
          'other{{count} items}} in your cart."}';
      final document = parseJson(text);
      expect(texts(document), [
        'no items',
        'one item',
        '⟨1⟩ items',
        'You have ⟨1⟩ in your cart.',
      ]);
      expectRoundTrip(document, text);
      final output = document.render([
        'keine Artikel',
        'einen Artikel',
        '⟨1⟩ Artikel',
        'Du hast ⟨1⟩ im Warenkorb.',
      ]);
      expect(
        (jsonDecode(output) as Map<String, dynamic>)['cart'],
        'Du hast {count, plural, =0{keine Artikel} =1{einen Artikel} '
        'other{{count} Artikel}} im Warenkorb.',
      );
    });

    test('handles #, offset, select and selectordinal', () {
      const text =
          '{"a": "{n, plural, offset:1 one{# guest} other{# guests}}", '
          '"b": "{gender, select, male{He} female{She} other{They}} replied", '
          '"c": "{n, selectordinal, one{#st} two{#nd} few{#rd} other{#th}}"}';
      final document = parseJson(text);
      expect(texts(document), [
        '⟨1⟩ guest',
        '⟨1⟩ guests',
        'He',
        'She',
        'They',
        '⟨1⟩ replied',
        '⟨1⟩st',
        '⟨1⟩nd',
        '⟨1⟩rd',
        '⟨1⟩th',
      ]);
      expectRoundTrip(document, text);
      expect(
        (jsonDecode(renderUpper(document)) as Map<String, dynamic>)['a'],
        '{n, plural, offset:1 one{# GUEST} other{# GUESTS}}',
      );
    });

    test('formatted arguments and other placeholders are protected', () {
      const text =
          '{"a": "Total: {price, number, currency} on {d, date, short}", '
          r'"b": "Hi {{name}}, %s has %1$d new <b>messages</b>", '
          r'"c": "See $t(common.more) or @:links.home", '
          '"d": "Unbalanced { brace"}';
      final document = parseJson(text);
      expect(texts(document), [
        'Total: ⟨1⟩ on ⟨2⟩',
        'Hi ⟨1⟩, ⟨2⟩ has ⟨3⟩ new ⟨4⟩messages⟨5⟩',
        'See ⟨1⟩ or ⟨2⟩',
        'Unbalanced { brace',
      ]);
      expectRoundTrip(document, text);
    });

    test('skips values that are not natural language', () {
      const text = '''
{
  "url": "https://example.com/path",
  "mail": "team@example.com",
  "id": "home_screen",
  "camel": "primaryColor",
  "const": "MAX_VALUE",
  "path": "assets/images/logo.png",
  "color": "#FF00AA",
  "number": "12.50",
  "placeholder": "{count}",
  "version": "v2",
  "dotted": "app.title",
  "word": "Cancel",
  "hyphen": "Sign-in",
  "sentence": "Open settings"
}
''';
      final document = parseJson(text);
      expect(texts(document), ['Cancel', 'Sign-in', 'Open settings']);
      expectRoundTrip(document, text);
    });

    test('re-escapes changed values and keeps escapes of unchanged ones', () {
      const text = r'{"a": "Line\nbreak \"quoted\"", "b": "caf\u00e9 \/ ok"}';
      final document = parseJson(text);
      expect(texts(document), ['Line\nbreak "quoted"', 'café / ok']);
      expectRoundTrip(document, text);
      final output = document.render(['Zeile\nUmbruch "zitiert"', null]);
      expect(
        output,
        r'{"a": "Zeile\nUmbruch \"zitiert\"", "b": "caf\u00e9 \/ ok"}',
      );
    });

    test('top-level arrays and nested arrays', () {
      const text = '["Hello", ["World", 1.5e3], {"k": "Value"}]';
      final document = parseJson(text);
      expect(texts(document), ['Hello', 'World', 'Value']);
      expect(document.segments.map((s) => s.label), ['[0]', '[1][0]', '[2].k']);
      expectRoundTrip(document, text);
    });

    test('plural without translatable outer text', () {
      const text = '{"n": "{count, plural, one{1 file} other{{count} files}}"}';
      final document = parseJson(text);
      expect(texts(document), ['1 file', '⟨1⟩ files']);
      expectRoundTrip(document, text);
      expect(
        (jsonDecode(renderUpper(document)) as Map<String, dynamic>)['n'],
        '{count, plural, one{1 FILE} other{{count} FILES}}',
      );
    });

    test('throws DocumentParseException for invalid JSON', () {
      expect(() => parseJson('{"a": '), throwsA(isA<DocumentParseException>()));
      expect(
        const DocumentParseException('x').toString(),
        'DocumentParseException: x',
      );
    });
  });

  group('IcuMessageParser', () {
    List<Piece> parse(String text) =>
        IcuMessageParser(text, DocumentBuilder()).parse();

    test('rejects malformed messages', () {
      for (final bad in [
        'a } b',
        '{',
        '{}',
        '{{name',
        '{n, plural, one{x}',
        '{n, plural, one}',
        '{n, plural, }',
        '{n plural}',
        '{n, number',
        '{n, plural one{x}}',
        '{n, plural, one{x} {y}}',
        '{n, plural, one{x',
      ]) {
        expect(() => parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('creates no segments when the message is malformed', () {
      final builder = DocumentBuilder();
      expect(
        () => IcuMessageParser(
          '{n, plural, one{one item} other{many items}',
          builder,
        ).parse(),
        throwsFormatException,
      );
      expect(builder.segmentCount, 0);
    });
  });

  group('looksLikeNaturalLanguage', () {
    test('accepts words and sentences', () {
      for (final text in ['OK', 'Save', 'e.g.', 'Hello world', 'Ünïcödé']) {
        expect(looksLikeNaturalLanguage(text), isTrue, reason: text);
      }
    });

    test('rejects identifiers, paths and codes', () {
      for (final text in ['', '123', 'snake_case', 'camelCase', 'A_B', 'a/b']) {
        expect(looksLikeNaturalLanguage(text), isFalse, reason: text);
      }
    });
  });
}
