import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('DocumentBuilder', () {
    test('moves edge whitespace and keeps symbols verbatim', () {
      final builder = DocumentBuilder()
        ..addContent([const TextPiece('  Hello  ')])
        ..literal('|')
        ..addContent([const TextPiece(' 42 ')])
        ..addContent([TokenPiece.text('`x`'), const TextPiece(' ')]);
      final document = builder.build(DocumentFormat.plainText);
      expect(texts(document), ['Hello']);
      expect(document.render(), '  Hello  | 42 `x` ');
      expect(document.render(['Hallo']), '  Hallo  | 42 `x` ');
      expect(document.nodes.whereType<TextNode>().length, 2);
    });

    test('pieces whose source differs from their text', () {
      final builder = DocumentBuilder()
        ..addContent([
          const TextPiece('one'),
          const TextPiece('\n> ', '\n'),
          const TextPiece('two'),
        ], continuation: '> ');
      final document = builder.build(DocumentFormat.markdown);
      expect(texts(document), ['one\ntwo']);
      expectRoundTrip(document, 'one\n> two');
      expect(document.render(['eins\nzwei\ndrei']), 'eins\n> zwei\n> drei');
    });

    test('placeholders beyond four digits', () {
      // A segment with more protected spans than four digits can number.
      const count = 10002;
      final builder = DocumentBuilder()
        ..addContent([
          for (var i = 1; i <= count; i++) ...[
            TextPiece('w$i '),
            TokenPiece.text('<$i>'),
          ],
        ]);
      final document = builder.build(DocumentFormat.plainText);
      final text = texts(document).single;
      expect(text, startsWith('w1 ⟨1⟩'));
      expect(text, endsWith('w10002 ⟨10002⟩'));
      // An engine that kept them, with spaces and CJK brackets.
      final translation = text
          .replaceAll('w', 'v')
          .replaceAll('⟨10001⟩', '〈 10001 〉');
      final output = document.render([translation]);
      expect(output, contains('v9999 <9999>v10000 <10000>v10001'));
      expect(output, endsWith('v10001 <10001>v10002 <10002>'));
      expect(output, isNot(contains('⟨')));
      // Old-style numbers still restore; a seven-digit one is text.
      expect(placeholderPattern.firstMatch('⟨ 12 ⟩')?.group(1), '12');
      expect(placeholderPattern.firstMatch('⟨999999⟩')?.group(1), '999999');
      expect(placeholderPattern.hasMatch('⟨1000000⟩'), isFalse);
    });

    test('accept can reject a segment', () {
      final builder = DocumentBuilder()
        ..addContent([const TextPiece('snake_case')], accept: (_) => false);
      final document = builder.build(DocumentFormat.json);
      expect(document.isEmpty, isTrue);
      expect(document.render(), 'snake_case');
    });

    test('protect splits on matches and handles no pattern', () {
      expect(protect('', RegExp('x')).single, isA<TextPiece>());
      expect(protect('abc', null).single, isA<TextPiece>());
      final pieces = protect('a1b22', RegExp(r'\d*'));
      expect(pieces.length, 4);
      expect(containsLetter('123 !'), isFalse);
      expect(containsLetter('ß'), isTrue);
    });
  });

  group('ParsedDocument', () {
    test('segment helpers, counts and labels', () {
      final document = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\n<i>Hi</i> there\n',
        DocumentFormat.srt,
      );
      expect(
        document.segments.single,
        const Segment('⟨1⟩Hi⟨2⟩ there', label: '1'),
      );
      expect(document.characterCount, '⟨1⟩Hi⟨2⟩ there'.length);
      expect(document.segmentSource(0), '<i>Hi</i> there');
      expect(document.segmentOutput(0, '⟨1⟩Hola⟨2⟩ allí'), '<i>Hola</i> allí');
      expect(placeholder(3), '⟨3⟩');
    });

    test('escapes translated text, never originals or placeholders', () {
      final builder = DocumentBuilder()
        ..addContent([
          const TextPiece('Tom &amp; Jerry', 'Tom & Jerry'),
          TokenPiece.text('<b/>'),
        ], escape: (text) => text.replaceAll('&', '&amp;'));
      final document = builder.build(DocumentFormat.html);
      expect(texts(document), ['Tom & Jerry⟨1⟩']);
      expect(document.render(), 'Tom &amp; Jerry<b/>');
      expect(document.render(['Tom & Jerry⟨1⟩']), 'Tom &amp; Jerry<b/>');
      expect(document.render(['A & B⟨1⟩ & C']), 'A &amp; B<b/> &amp; C');
      expect(document.segmentOutput(0, 'X & ⟨1⟩'), 'X &amp;<b/>');
    });

    test('tolerates CJK brackets, spaces and out-of-range placeholders', () {
      final document = parseMarkdown('Press `Ctrl` now');
      expect(texts(document), ['Press ⟨1⟩ now']);
      expect(document.render(['〈 1 〉を押す ⟨9⟩']), '`Ctrl`を押す ⟨9⟩\n'.trim());
    });

    test('appends a lost glued placeholder without a space', () {
      final document = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n',
        DocumentFormat.srt,
      );
      expect(texts(document), ['⟨1⟩Hello⟨2⟩']);
      expect(document.render(['⟨1⟩Hola']), contains('<i>Hola</i>\n'));
    });

    test('missing translations keep the original', () {
      final document = parsePlainText('a\n\nb');
      expect(document.render(['A']), 'A\n\nb');
      expect(document.render([null, 'B']), 'a\n\nB');
      expect(document.renderBilingual(['A', null]), 'a\nA\n\nb');
    });

    test('encoded nodes re-encode only when something changed', () {
      final document = parseJson(r'{"a": "x \u0041 y", "b": "Same"}');
      final output = document.render(['x A y', 'Gleich']);
      expect(output, r'{"a": "x \u0041 y", "b": "Gleich"}');
      expect(jsonDecode(output), {'a': 'x A y', 'b': 'Gleich'});
    });

    test('TextNode describes itself', () {
      expect(const TextNode('a\nb').toString(), r'TextNode(a\nb)');
    });
  });
}
