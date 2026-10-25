import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

void main() {
  group('BatchCodec', () {
    test('encodes markers one per line', () {
      expect(
        BatchCodec.encode(['Hello', 'Two\nlines'], ChunkEncoding.markers),
        '⟦1⟧ Hello\n⟦2⟧ Two\nlines',
      );
      expect(BatchCodec.encode(['A', 'B'], ChunkEncoding.paragraphs), 'A\n\nB');
      expect(BatchCodec.encode(['A'], ChunkEncoding.single), 'A');
    });

    test('decodes markers anywhere, tolerating spaces and [[n]]', () {
      expect(
        BatchCodec.decode(
          'Sure:\n⟦1⟧ Hola ⟦ 2 ⟧Dos\r\nlíneas\n[[3]] Tres\n',
          3,
          ChunkEncoding.markers,
        ),
        ['Hola', 'Dos\nlíneas', 'Tres'],
      );
    });

    test('returns null when markers are lost, duplicated or reordered', () {
      for (final output in [
        'Hola Dos',
        '⟦1⟧ Hola',
        '⟦1⟧ Hola ⟦1⟧ Dos',
        '⟦2⟧ Dos ⟦1⟧ Hola',
        '⟦1⟧ Hola ⟦2⟧ Dos ⟦3⟧ Tres',
        '⟦1⟧ ⟦2⟧ Dos',
        '⟦1⟧ Hola ⟦2⟧',
      ]) {
        expect(
          BatchCodec.decode(output, 2, ChunkEncoding.markers),
          isNull,
          reason: output,
        );
      }
    });

    test('decodes paragraphs and checks their number', () {
      expect(
        BatchCodec.decode('\nUno\n  \nDos\ntres\n\n\nCuatro\n', 3, .paragraphs),
        ['Uno', 'Dos\ntres', 'Cuatro'],
      );
      expect(BatchCodec.decode('Uno\nDos', 2, .paragraphs), isNull);
      expect(BatchCodec.decode('', 1, .paragraphs), isNull);
      expect(BatchCodec.decode('  Solo \n', 1, .single), ['Solo']);
      expect(BatchCodec.decode('  ', 1, .single), isNull);
    });

    test('detects blank lines', () {
      expect(BatchCodec.hasBlankLine('a\n\nb'), isTrue);
      expect(BatchCodec.hasBlankLine('a\r\n \r\nb'), isTrue);
      expect(BatchCodec.hasBlankLine('a\nb'), isFalse);
    });
  });

  group('splitText', () {
    test('keeps short text whole', () {
      expect(splitText('short', 10), [(text: 'short', separator: '')]);
    });

    test('prefers line breaks, then sentence ends, then spaces', () {
      final lines = splitText('aaaa bbbb\ncccc dddd', 12);
      expect(lines, [
        (text: 'aaaa bbbb', separator: '\n'),
        (text: 'cccc dddd', separator: ''),
      ]);

      final sentences = splitText('One two. Three four five six.', 20);
      expect(sentences.first, (text: 'One two.', separator: ' '));

      final spaces = splitText('aaaa bbbb cccc dddd', 12);
      expect(spaces.first, (text: 'aaaa bbbb', separator: ' '));
    });

    test('drops trailing spaces before a cut into the separator', () {
      final parts = splitText('aaaa bbbb   \ncccc dddd', 14);
      expect(parts.first, (text: 'aaaa bbbb', separator: '   \n'));
      expect(
        parts.map((p) => '${p.text}${p.separator}').join(),
        'aaaa bbbb   \ncccc dddd',
      );
    });

    test('splits CJK text after sentence punctuation without spaces', () {
      final parts = splitText('今日は晴れです。明日は雨でしょう。', 10);
      expect(parts.first, (text: '今日は晴れです。', separator: ''));
    });

    test('cuts hard but never inside a placeholder or surrogate pair', () {
      final placeholder = splitText('abcdefgh⟨12⟩ijk', 10);
      expect(placeholder.first.text, 'abcdefgh');
      expect(placeholder.map((p) => p.text).join(), 'abcdefgh⟨12⟩ijk');

      const emoji = 'abcdefghi😀xyz';
      final surrogate = splitText(emoji, 10);
      expect(surrogate.first.text, 'abcdefghi');
      expect(surrogate[1].text, startsWith('😀'));
    });

    test('joining parts and separators restores the text', () {
      final text = List.filled(50, 'Lorem ipsum dolor sit amet.').join(' ');
      final parts = splitText(text, 100);
      expect(parts.every((p) => p.text.length <= 100), isTrue);
      expect(parts.map((p) => '${p.text}${p.separator}').join(), text);
    });
  });

  group('Chunker', () {
    List<Segment> segments(List<String> texts) => [
      for (final text in texts) Segment(text),
    ];

    test('chooses the batch encoding per format', () {
      expect(
        Chunker.encodingFor(DocumentFormat.plainText),
        ChunkEncoding.paragraphs,
      );
      expect(
        Chunker.encodingFor(DocumentFormat.markdown),
        ChunkEncoding.paragraphs,
      );
      expect(Chunker.encodingFor(DocumentFormat.srt), ChunkEncoding.markers);
      expect(Chunker.encodingFor(DocumentFormat.vtt), ChunkEncoding.markers);
      expect(Chunker.encodingFor(DocumentFormat.json), ChunkEncoding.markers);
    });

    test('batches web pages as paragraphs and string files with markers', () {
      expect(
        Chunker.encodingFor(DocumentFormat.html),
        ChunkEncoding.paragraphs,
      );
      for (final format in [
        DocumentFormat.xliff,
        DocumentFormat.androidStrings,
        DocumentFormat.po,
        DocumentFormat.csv,
        DocumentFormat.tsv,
        DocumentFormat.appleStrings,
        DocumentFormat.xcstrings,
      ]) {
        expect(
          Chunker.encodingFor(format),
          ChunkEncoding.markers,
          reason: '$format',
        );
      }
    });

    test('groups segments up to the size limit', () {
      final plan = const Chunker(maxCharacters: 60).planSegments(
        segments(['a' * 20, 'b' * 20, 'c' * 20, 'd' * 5]),
        ChunkEncoding.markers,
      );
      expect(plan.chunks.map((c) => c.units.length), [2, 2]);
      expect(plan.chunks.first.encoding, ChunkEncoding.markers);
      expect(plan.chunks.first.payload, '⟦1⟧ ${'a' * 20}\n⟦2⟧ ${'b' * 20}');
      expect(plan.chunks.first.firstSegment, 0);
      expect(plan.chunks.first.lastSegment, 1);
      expect(plan.chunks.every((c) => c.length <= 60), isTrue);
      expect(plan.segmentCount, 4);
      expect(plan.characterCount, greaterThan(65));
    });

    test('respects the unit limit and uses single for lone units', () {
      final plan = const Chunker(maxUnits: 2)
          .planSegments(segments(['a', 'b', 'c']), ChunkEncoding.paragraphs);
      expect(plan.chunks.map((c) => c.encoding), [
        ChunkEncoding.paragraphs,
        ChunkEncoding.single,
      ]);
      expect(plan.chunks.first.payload, 'a\n\nb');
    });

    test('falls back to markers when a unit has a blank line', () {
      final plan = const Chunker().planSegments(
        segments(['a\n\nb', 'c']),
        ChunkEncoding.paragraphs,
      );
      expect(plan.chunks.single.encoding, ChunkEncoding.markers);
    });

    test('splits oversized segments and assembles them back', () {
      final long = List.filled(30, 'Sentence number one.').join(' ');
      final plan = const Chunker(maxCharacters: 100).planSegments(
        segments(['Short', long, 'Tail']),
        ChunkEncoding.paragraphs,
      );
      expect(plan.separators[0], isEmpty);
      expect(plan.separators[1], isNotEmpty);
      final units = plan.chunks.expand((c) => c.units).toList();
      expect(units.where((u) => u.segment == 1).length, greaterThan(5));

      final results = {
        for (final chunk in plan.chunks)
          chunk.index: [for (final unit in chunk.units) unit.text],
      };
      expect(plan.assemble(results), ['Short', long, 'Tail']);
    });

    test('assemble leaves incomplete segments null', () {
      final plan = const Chunker(maxCharacters: 60)
          .planSegments(segments(['x' * 100, 'y']), ChunkEncoding.paragraphs);
      final first = plan.chunks.first;
      final partial = plan.assemble({
        first.index: [for (final unit in first.units) unit.text.toUpperCase()],
        99: ['ignored'],
      });
      expect(partial, [null, null]);
      expect(plan.assemble(const {}), [null, null]);
    });

    test('plans a parsed document and handles empty input', () {
      final document = parsePlainText('One\n\nTwo');
      final plan = const Chunker().plan(document);
      expect(plan.chunks.single.payload, 'One\n\nTwo');
      expect(plan.chunks.single.split('Uno\n\nDos'), ['Uno', 'Dos']);
      expect(const Chunker().plan(parsePlainText('')).chunks, isEmpty);
    });

    test('value equality', () {
      const unit = TranslationUnit(segment: 0, part: 0, text: 'a');
      expect(unit, const TranslationUnit(segment: 0, part: 0, text: 'a'));
      final plan = const Chunker().plan(parsePlainText('a'));
      expect(plan, const Chunker().plan(parsePlainText('a')));
    });
  });
}
