import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/block_batcher.dart';

void main() {
  group('BlockBatcher', () {
    List<TranslationItem> items(List<int> lengths) => [
      for (var i = 0; i < lengths.length; i++)
        TranslationItem(i, 'x' * lengths[i]),
    ];

    List<List<int>> ids(List<List<TranslationItem>> batches) => [
      for (final batch in batches) [for (final item in batch) item.id],
    ];

    test('packs items up to the character limit', () {
      const batcher = BlockBatcher(maxChars: 100);
      expect(ids(batcher.batch(items([40, 40, 40, 10]))), [
        [0, 1],
        [2, 3],
      ]);
    });

    test('counts the separators', () {
      const batcher = BlockBatcher(maxChars: 100);
      // 49 + 2 + 49 = 100 fits; one more character does not.
      expect(ids(batcher.batch(items([49, 49]))), [
        [0, 1],
      ]);
      expect(ids(batcher.batch(items([49, 50]))), [
        [0],
        [1],
      ]);
    });

    test('sends long items alone', () {
      const batcher = BlockBatcher(maxChars: 100);
      expect(ids(batcher.batch(items([10, 500, 10]))), [
        [0],
        [1],
        [2],
      ]);
    });

    test('limits the number of items', () {
      const batcher = BlockBatcher(maxItems: 2);
      expect(ids(batcher.batch(items([1, 1, 1, 1, 1]))), [
        [0, 1],
        [2, 3],
        [4],
      ]);
    });

    test('handles no items', () {
      expect(const BlockBatcher().batch(const []), isEmpty);
    });

    test('join and split round-trip', () {
      const batch = [
        TranslationItem(0, 'One'),
        TranslationItem(1, 'Two\nlines'),
        TranslationItem(2, 'Three'),
      ];
      final joined = BlockBatcher.join(batch);
      expect(joined, 'One\n\nTwo\nlines\n\nThree');
      expect(BlockBatcher.split(joined, 3), ['One', 'Two\nlines', 'Three']);
    });

    test('split tolerates extra blank lines and whitespace', () {
      expect(BlockBatcher.split('\n Uno \n \n\n\nDos\r\n\r\nTres\n', 3), [
        'Uno',
        'Dos',
        'Tres',
      ]);
    });

    test('split returns null when paragraphs were merged or split', () {
      expect(BlockBatcher.split('Uno Dos', 2), isNull);
      expect(BlockBatcher.split('A\n\nB\n\nC', 2), isNull);
    });

    test('items compare by value', () {
      final a = TranslationItem(1, 'a'.toUpperCase());
      const b = TranslationItem(1, 'A');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const TranslationItem(2, 'A'), isFalse);
    });
  });
}
