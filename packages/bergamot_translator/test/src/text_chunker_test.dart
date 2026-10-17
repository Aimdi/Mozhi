import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextChunker.split', () {
    test('keeps short text whole', () {
      expect(TextChunker.split('Hello.'), ['Hello.']);
      expect(TextChunker.split(''), ['']);
    });

    test('prefers paragraph breaks', () {
      const text = 'One two three.\n\nFour five six.\n\nSeven.';
      final pieces = TextChunker.split(text, maxLength: 20);
      expect(pieces, ['One two three.\n\n', 'Four five six.\n\n', 'Seven.']);
      expect(pieces.join(), text);
    });

    test('then line breaks', () {
      const text = 'Line one here\nLine two here\nLine three';
      final pieces = TextChunker.split(text, maxLength: 16);
      expect(pieces, ['Line one here\n', 'Line two here\n', 'Line three']);
    });

    test('then sentence ends', () {
      const text = 'First sentence. Second one! Third? Fourth';
      final pieces = TextChunker.split(text, maxLength: 18);
      expect(pieces.first, 'First sentence. ');
      expect(pieces.join(), text);
      for (final piece in pieces) {
        expect(piece.length, lessThanOrEqualTo(18));
      }
    });

    test('handles CJK sentence ends', () {
      const text = '你好。今天天气很好。我们去公园吧。';
      final pieces = TextChunker.split(text, maxLength: 8);
      expect(pieces, ['你好。', '今天天气很好。', '我们去公园吧。']);
    });

    test('then spaces', () {
      const text = 'aaaa bbbb cccc dddd';
      final pieces = TextChunker.split(text, maxLength: 10);
      expect(pieces, ['aaaa bbbb ', 'cccc dddd']);
    });

    test('cuts a single long word, never inside a surrogate pair', () {
      final pieces = TextChunker.split('abcdefghij', maxLength: 4);
      expect(pieces, ['abcd', 'efgh', 'ij']);
      const emoji = 'ab😀cd';
      final split = TextChunker.split(emoji, maxLength: 3);
      expect(split.join(), emoji);
      expect(split.first, 'ab');
    });

    test('long text round-trips and respects the limit', () {
      final text = List.generate(
        400,
        (i) => 'Sentence number $i is here.${i % 7 == 0 ? '\n\n' : ' '}',
      ).join();
      final pieces = TextChunker.split(text, maxLength: 500);
      expect(pieces.join(), text);
      expect(pieces.length, greaterThan(10));
      for (final piece in pieces) {
        expect(piece.length, lessThanOrEqualTo(500));
      }
    });

    test('rejects a non-positive limit', () {
      expect(() => TextChunker.split('x', maxLength: 0), throwsArgumentError);
    });
  });
}
