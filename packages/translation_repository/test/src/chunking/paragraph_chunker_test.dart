import 'dart:math';

import 'package:test/test.dart';
import 'package:translation_repository/src/chunking/paragraph_chunker.dart';

/// The chunk texts joined with their separators.
String rejoin(List<TextChunk> chunks) =>
    ParagraphChunker.join(chunks, [for (final chunk in chunks) chunk.text]);

/// A paragraph of [length] characters (words of 4 letters, no full stop).
String paragraph(String letter, int length) {
  final words = List.filled((length + 1) ~/ 5, letter * 4).join(' ');
  return words.padRight(length, letter).substring(0, length);
}

void main() {
  group(TextChunk, () {
    test('has value equality', () {
      expect(
        const TextChunk(text: 'a', separator: '\n\n'),
        const TextChunk(text: 'a', separator: '\n\n'),
      );
      expect(
        const TextChunk(text: 'a', separator: '\n\n').hashCode,
        const TextChunk(text: 'a', separator: '\n\n').hashCode,
      );
      expect(
        const TextChunk(text: 'a'),
        isNot(const TextChunk(text: 'a', separator: ' ')),
      );
      expect(const TextChunk(text: 'a'), isNot(const TextChunk(text: 'b')));
      expect(const TextChunk(text: 'a').separator, isEmpty);
    });

    test('toString shows the sizes', () {
      expect(
        const TextChunk(text: 'abc', separator: '\n\n').toString(),
        'TextChunk(3 chars, separator: 2 chars)',
      );
    });
  });

  group('ParagraphChunker.split', () {
    test('rejects a limit below 1', () {
      expect(
        () => ParagraphChunker.split('Hello', maxChars: 0),
        throwsArgumentError,
      );
    });

    test('returns nothing for blank text', () {
      expect(ParagraphChunker.split('', maxChars: 10), isEmpty);
      expect(ParagraphChunker.split(' \n\t\n ', maxChars: 10), isEmpty);
    });

    test('returns short text as one trimmed chunk', () {
      expect(ParagraphChunker.split('\n\n  Hello world.\n', maxChars: 100), [
        const TextChunk(text: 'Hello world.'),
      ]);
    });

    test('keeps text exactly at the limit in one chunk', () {
      expect(ParagraphChunker.split('a' * 10, maxChars: 10), [
        TextChunk(text: 'a' * 10),
      ]);
    });

    test('splits at blank lines and keeps every separator verbatim', () {
      final a = paragraph('a', 30);
      final b = paragraph('b', 30);
      final c = paragraph('c', 30);
      final text = '$a\n\n$b  \n \t\n$c';
      final chunks = ParagraphChunker.split(text, maxChars: 35);
      expect(chunks, [
        TextChunk(text: a, separator: '\n\n'),
        TextChunk(text: b, separator: '  \n \t\n'),
        TextChunk(text: c),
      ]);
      expect(rejoin(chunks), text);
    });

    test('keeps Windows line breaks in separators', () {
      final a = paragraph('a', 30);
      final b = paragraph('b', 30);
      final chunks = ParagraphChunker.split('$a\r\n\r\n$b', maxChars: 35);
      expect(chunks, [
        TextChunk(text: a, separator: '\r\n\r\n'),
        TextChunk(text: b),
      ]);
    });

    test('packs several paragraphs into one chunk', () {
      final parts = [for (final l in 'abcd'.split('')) paragraph(l, 20)];
      final text = parts.join('\n\n');
      final chunks = ParagraphChunker.split(text, maxChars: 50);
      expect(chunks.map((c) => c.text), [
        '${parts[0]}\n\n${parts[1]}',
        '${parts[2]}\n\n${parts[3]}',
      ]);
      expect(chunks.first.separator, '\n\n');
      expect(rejoin(chunks), text);
    });

    test('balances the chunks instead of filling the first one', () {
      final parts = [for (var i = 0; i < 10; i++) paragraph('x', 50)];
      final text = parts.join('\n\n');
      expect(text.length, 518);
      final chunks = ParagraphChunker.split(text, maxChars: 400);
      // Greedy filling would give 362 + 154 characters.
      expect(chunks.map((c) => c.text.length), [310, 206]);
      expect(rejoin(chunks), text);
    });

    test('drops whitespace around the text', () {
      final a = paragraph('a', 30);
      final b = paragraph('b', 30);
      final chunks = ParagraphChunker.split('\n  $a\n\n$b \n\n', maxChars: 35);
      expect(chunks.first.text, a);
      expect(chunks.last, TextChunk(text: b));
    });

    test('splits an overlong paragraph at line breaks first', () {
      final lines = [for (final l in 'abc'.split('')) '- ${paragraph(l, 20)}.'];
      final text = lines.join('\n');
      final chunks = ParagraphChunker.split(text, maxChars: 30);
      expect(chunks.map((c) => c.text), lines);
      expect(chunks.map((c) => c.separator), ['\n', '\n', '']);
    });

    test('splits an overlong paragraph at sentence ends', () {
      const text =
          'The first sentence is here. The second one follows! '
          'Is this the third? "Quoted ending." Last words';
      final chunks = ParagraphChunker.split(text, maxChars: 30);
      expect(chunks.map((c) => c.text), [
        'The first sentence is here.',
        'The second one follows!',
        'Is this the third?',
        '"Quoted ending." Last words',
      ]);
      expect(rejoin(chunks), text);
    });

    test('prefers paragraph boundaries over sentence ends', () {
      const text =
          'One. Two. Three.\n\nFour. Five. Six. Seven. Eight. Nine. Ten.';
      final chunks = ParagraphChunker.split(text, maxChars: 50);
      expect(
        chunks.first,
        const TextChunk(text: 'One. Two. Three.', separator: '\n\n'),
      );
      expect(rejoin(chunks), text);
    });

    test('splits an overlong sentence between words', () {
      final text = List.filled(12, 'word').join(' ');
      final chunks = ParagraphChunker.split(text, maxChars: 20);
      expect(chunks.every((c) => c.text.length <= 20), isTrue);
      expect(chunks.every((c) => !c.text.contains(RegExp(r'^\s|\s$'))), isTrue);
      expect(
        chunks.map((c) => c.separator).take(chunks.length - 1),
        everyElement(' '),
      );
      expect(rejoin(chunks), text);
    });

    test('cuts a word longer than the limit', () {
      final text = 'x' * 25;
      final chunks = ParagraphChunker.split(text, maxChars: 10);
      expect(chunks.map((c) => c.text.length), [10, 10, 5]);
      expect(chunks.map((c) => c.separator), everyElement(isEmpty));
      expect(rejoin(chunks), text);
    });

    test('never cuts a surrogate pair apart', () {
      final text = '😀' * 10; // 20 UTF-16 code units
      final chunks = ParagraphChunker.split(text, maxChars: 5);
      for (final chunk in chunks) {
        expect(chunk.text.runes.every((r) => r == 0x1F600), isTrue);
      }
      expect(rejoin(chunks), text);
    });

    test('keeps a surrogate pair together with a limit of 1', () {
      final chunks = ParagraphChunker.split('a😀b', maxChars: 1);
      expect(chunks.map((c) => c.text), ['a', '😀', 'b']);
    });

    test('cuts CJK text after full stops', () {
      const text = '今日は晴れです。明日は雨です。明後日は雪です。';
      final chunks = ParagraphChunker.split(text, maxChars: 10);
      expect(chunks.map((c) => c.text), ['今日は晴れです。', '明日は雨です。', '明後日は雪です。']);
      expect(chunks.map((c) => c.separator), everyElement(isEmpty));
      expect(rejoin(chunks), text);
    });

    test('keeps a CJK closing quote with its sentence', () {
      const text = '「こんにちは。」と言った。それから帰った。';
      final chunks = ParagraphChunker.split(text, maxChars: 12);
      expect(chunks.first.text, '「こんにちは。」');
      expect(rejoin(chunks), text);
    });

    group('code blocks', () {
      test('never splits at blank lines inside a fenced block', () {
        final before = paragraph('a', 20);
        const code = '```dart\nvoid main() {\n\n  print(1);\n\n}\n```';
        final after = paragraph('b', 20);
        final text = '$before\n\n$code\n\n$after';
        final chunks = ParagraphChunker.split(text, maxChars: 40);
        expect(chunks.map((c) => c.text), [before, code, after]);
        expect(rejoin(chunks), text);
      });

      test('keeps an overlong block whole', () {
        final code =
            '~~~\n${List.filled(10, 'line one. line two.').join('\n')}'
            '\n~~~';
        final text = 'Intro text.\n\n$code\n\nOutro.';
        final chunks = ParagraphChunker.split(text, maxChars: 30);
        expect(chunks.map((c) => c.text), contains(code));
        expect(rejoin(chunks), text);
      });

      test('keeps an unclosed block whole to the end', () {
        const code = '```\nint a;\n\nint b;\n\nint c;';
        const text = 'Intro text here.\n\n$code';
        final chunks = ParagraphChunker.split(text, maxChars: 20);
        expect(chunks.map((c) => c.text), ['Intro text here.', code]);
      });

      test('needs a matching closing fence', () {
        // ~~~ and a shorter ``` do not close a ```` block.
        const code = '````\na\n\n~~~\n\nb\n\n```\n\nc\n````';
        const text = 'Before.\n\n$code\n\nAfter.';
        final chunks = ParagraphChunker.split(text, maxChars: 12);
        expect(chunks.map((c) => c.text), ['Before.', code, 'After.']);
      });

      test('does not open a block on a backtick line with backticks', () {
        // "``` a ` b" is inline code, not a fence.
        const text = '``` a ` b\n\nsecond paragraph\n\nthird paragraph';
        final chunks = ParagraphChunker.split(text, maxChars: 20);
        expect(chunks.map((c) => c.text), [
          '``` a ` b',
          'second paragraph',
          'third paragraph',
        ]);
      });

      test('allows an indented fence and a closing fence with spaces', () {
        const code = '   ```\n   x\n\n   y\n   ```  ';
        const text = 'Start of it.\n\n$code\n\nEnd of it.';
        final chunks = ParagraphChunker.split(text, maxChars: 15);
        expect(chunks.map((c) => c.text), [
          'Start of it.',
          '```\n   x\n\n   y\n   ```',
          'End of it.',
        ]);
        expect(chunks[0].separator, '\n\n   ');
        expect(chunks[1].separator, '  \n\n');
        expect(rejoin(chunks), text.trim());
      });

      test('cuts a long word before a block rather than inside it', () {
        final text = '${'x' * 8}\n```\ny\n\nz\n```';
        final chunks = ParagraphChunker.split(text, maxChars: 5);
        expect(chunks.last.text, '```\ny\n\nz\n```');
        expect(rejoin(chunks), text);
      });

      test('splits text directly after a block that ends without space', () {
        // A block followed by a run without whitespace up to the limit.
        final text = '```\na\n\nb\n```\n${'z' * 12}';
        final chunks = ParagraphChunker.split(text, maxChars: 6);
        expect(chunks.first.text, '```\na\n\nb\n```');
        expect(rejoin(chunks), text);
      });
    });

    test('reproduces any text when joined', () {
      final random = Random(7);
      final pieces = [
        'Word',
        'word.',
        'Ende!',
        '?',
        ' ',
        '  ',
        '\n',
        '\n\n',
        '\n \n',
        '\t',
        '```',
        '~~~',
        '。',
        '漢字',
        '😀',
        'x' * 15,
      ];
      for (var round = 0; round < 300; round++) {
        final text = List.generate(
          random.nextInt(80),
          (_) => pieces[random.nextInt(pieces.length)],
        ).join();
        final maxChars = 1 + random.nextInt(40);
        final chunks = ParagraphChunker.split(text, maxChars: maxChars);
        expect(rejoin(chunks), text.trim(), reason: 'text: "$text"');
        for (final chunk in chunks) {
          expect(chunk.text, isNotEmpty);
          expect(chunk.text.trim(), chunk.text, reason: 'text: "$text"');
          expect(chunk.separator.trim(), isEmpty);
        }
        expect(chunks.isEmpty || chunks.last.separator.isEmpty, isTrue);
      }
    });
  });

  group('ParagraphChunker.join', () {
    test('joins parts with the separators', () {
      const chunks = [
        TextChunk(text: 'a', separator: '\n\n'),
        TextChunk(text: 'b', separator: ' '),
        TextChunk(text: 'c'),
      ];
      expect(ParagraphChunker.join(chunks, ['A', 'B', 'C']), 'A\n\nB C');
    });

    test('joins nothing to an empty string', () {
      expect(ParagraphChunker.join(const [], const []), '');
    });

    test('requires one part per chunk', () {
      expect(
        () => ParagraphChunker.join(const [TextChunk(text: 'a')], const []),
        throwsArgumentError,
      );
    });
  });
}
