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
      expect(
        const TextChunk(text: 'a'),
        isNot(const TextChunk(text: 'a', sentenceEnd: true)),
      );
      expect(
        const TextChunk(text: 'a', sentenceEnd: true).hashCode,
        const TextChunk(text: 'a', sentenceEnd: true).hashCode,
      );
      expect(const TextChunk(text: 'a').separator, isEmpty);
      expect(const TextChunk(text: 'a').sentenceEnd, isFalse);
    });

    test('toString shows the sizes', () {
      expect(
        const TextChunk(text: 'abc', separator: '\n\n').toString(),
        'TextChunk(3 chars, separator: 2 chars)',
      );
      expect(
        const TextChunk(text: 'abc。', sentenceEnd: true).toString(),
        'TextChunk(4 chars, separator: 0 chars, sentence end)',
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
      expect(chunks.map((c) => c.sentenceEnd), [true, true, false]);
      expect(rejoin(chunks), text);
    });

    test('marks only cuts after a CJK full stop as sentence ends', () {
      // Cut inside an overlong word, after a Latin full stop with a space,
      // and after a CJK full stop.
      final chunks = ParagraphChunker.split(
        '${'x' * 12} Ende. 今日は晴れです。明日は雨です。',
        maxChars: 10,
      );
      expect(chunks.map((c) => c.text), [
        'x' * 10,
        'xx',
        'Ende.',
        '今日は晴れです。',
        '明日は雨です。',
      ]);
      expect(chunks.map((c) => c.separator), ['', ' ', ' ', '', '']);
      expect(chunks.map((c) => c.sentenceEnd), [
        false,
        false,
        false,
        true,
        false,
      ]);
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

      test('treats an unclosed fence as text', () {
        // A stray fence must not make the rest one uncuttable part.
        const text = 'Intro\n\n```\nint a;\n\nint b;\n\nint c;';
        final chunks = ParagraphChunker.split(text, maxChars: 12);
        expect(chunks.map((c) => c.text), [
          'Intro',
          '```\nint a;',
          'int b;',
          'int c;',
        ]);
        expect(rejoin(chunks), text);
      });

      test('keeps a long text after a stray fence within the limit', () {
        final prose = List.filled(100, paragraph('p', 50)).join('\n\n');
        final text = 'Intro\n\n```\n$prose';
        final chunks = ParagraphChunker.split(text, maxChars: 500);
        expect(chunks.length, greaterThan(10));
        for (final chunk in chunks) {
          expect(chunk.text.length, lessThanOrEqualTo(500));
        }
        expect(rejoin(chunks), text);
      });

      test('still protects a block that follows a stray fence', () {
        // "```js" cannot close the stray "```", so the stray one stays
        // unclosed; the later ~~~ block is still a block.
        const code = '~~~\na\n\nb\n~~~';
        const text = 'One.\n\n```js\n\nTwo.\n\n$code\n\nThree.';
        final chunks = ParagraphChunker.split(text, maxChars: 10);
        expect(chunks.map((c) => c.text), [
          'One.',
          '```js',
          'Two.',
          code,
          'Three.',
        ]);
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

  group('ParagraphChunker.joiner', () {
    const cut = TextChunk(text: '这是测试。', sentenceEnd: true);

    test('is the separator of an ordinary chunk', () {
      const chunk = TextChunk(text: 'a', separator: '\n\n');
      expect(ParagraphChunker.joiner(chunk, 'A.', 'B'), '\n\n');
      expect(ParagraphChunker.joiner(const TextChunk(text: 'a'), 'A', 'B'), '');
    });

    test('is a space between sentences in scripts with spaces', () {
      expect(ParagraphChunker.joiner(cut, 'For the test.', 'This is'), ' ');
      expect(ParagraphChunker.joiner(cut, 'Тест.', 'Это'), ' ');
      expect(ParagraphChunker.joiner(cut, '시험입니다.', '다음'), ' ');
      expect(ParagraphChunker.joiner(cut, 'Done 😀', '😀 next'), ' ');
      expect(ParagraphChunker.joiner(cut, '.', 'N'), ' ');
    });

    test('is empty next to CJK text, whitespace or nothing', () {
      expect(ParagraphChunker.joiner(cut, 'テストです。', 'これは'), '');
      expect(ParagraphChunker.joiner(cut, 'Test.', '这是'), '');
      expect(ParagraphChunker.joiner(cut, '这是测试', 'Next'), '');
      expect(ParagraphChunker.joiner(cut, 'Test．', 'Next'), '');
      expect(ParagraphChunker.joiner(cut, 'Test.', '「Next」'), '');
      expect(ParagraphChunker.joiner(cut, 'Test.\n', 'Next'), '');
      expect(ParagraphChunker.joiner(cut, 'Test.', ' Next'), '');
      expect(ParagraphChunker.joiner(cut, '', 'Next'), '');
      expect(ParagraphChunker.joiner(cut, 'Test.', ''), '');
      expect(ParagraphChunker.joiner(cut, 'A𠀀', 'Next'), '');
      expect(ParagraphChunker.joiner(cut, 'Test.', '𠀀b'), '');
    });

    test('joinTranslations joins every part with it', () {
      const chunks = [
        TextChunk(text: '一。', sentenceEnd: true),
        TextChunk(text: '二', separator: '\n\n'),
        TextChunk(text: '三。'),
      ];
      expect(
        ParagraphChunker.joinTranslations(chunks, ['One.', 'Two', 'Three.']),
        'One. Two\n\nThree.',
      );
      expect(
        () => ParagraphChunker.joinTranslations(chunks, ['One.']),
        throwsArgumentError,
      );
    });

    test('joins Chinese text translated into English with spaces', () {
      final text = List.filled(40, '这是一个测试句子。').join();
      final chunks = ParagraphChunker.split(text, maxChars: 100);
      expect(chunks.length, greaterThan(1));
      final joined = ParagraphChunker.joinTranslations(chunks, [
        for (final _ in chunks) 'This is a test sentence.',
      ]);
      expect(joined, isNot(contains('.This')));
      expect(joined, contains('sentence. This'));
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
