// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/parsers/xliff_parser.dart';
import 'package:xml/xml.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('XLIFF 1.2 seg-source', () {
    const text =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<xliff version="1.2"><file source-language="en" datatype="plaintext" '
        'original="a.txt"><body>\n'
        '  <trans-unit id="1">\n'
        '    <source>Hello <g id="1">world</g>. How are you?</source>\n'
        '    <seg-source><mrk mtype="seg" mid="1">Hello <g id="1">world</g>.'
        '</mrk> <x id="2"/><mrk mtype="seg" mid="2">How are you?</mrk>'
        '</seg-source>\n'
        '  </trans-unit>\n'
        '  <trans-unit id="2">\n'
        '    <source>Only one.</source>\n'
        '    <seg-source>Only one.</seg-source>\n'
        '    <target/>\n'
        '  </trans-unit>\n'
        '</body></file></xliff>\n';

    test('mirrors the sentences into the target', () {
      final document = parseXliff(text, targetLanguage: 'de');
      expectRoundTrip(document, text);
      expect(texts(document), [
        'Hello ⟨1⟩world⟨2⟩.',
        'How are you?',
        'Only one.',
      ]);
      final output = document.render([
        'Hallo ⟨1⟩Welt⟨2⟩.',
        'Wie geht es dir?',
        'Nur eins.',
      ]);
      expect(
        output,
        contains(
          '</seg-source>\n    <target state="needs-review-translation">'
          '<mrk mtype="seg" mid="1">Hallo <g id="1">Welt</g>.</mrk> '
          '<x id="2"/><mrk mtype="seg" mid="2">Wie geht es dir?</mrk>'
          '</target>\n  </trans-unit>',
        ),
      );
      // Without marked sentences the target is flat.
      expect(
        output,
        contains('<target state="needs-review-translation">Nur eins.</target>'),
      );
      expect(() => XmlDocument.parse(output), returnsNormally);
    });

    test('keeps untranslated sentences as they are in the source', () {
      final document = parseXliff(text, targetLanguage: 'de');
      final output = document.render([null, 'Wie geht es dir?']);
      expect(
        output,
        contains(
          '<mrk mtype="seg" mid="1">Hello <g id="1">world</g>.</mrk> '
          '<x id="2"/><mrk mtype="seg" mid="2">Wie geht es dir?</mrk>'
          '</target>',
        ),
      );
    });
  });
}
