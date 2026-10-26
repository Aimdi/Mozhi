import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/speech/speech_chunker.dart';

typedef _Case = ({
  String name,
  String text,
  int maxLength,
  List<String> chunks,
});

final _startsWithMark = RegExp(r'^\p{M}', unicode: true);

const _family = '👨‍👩‍👧‍👦'; // 11 UTF-16 code units, one grapheme.

final _cases = <_Case>[
  // Latin.
  (
    name: 'Latin: prefers sentence, then clause ends',
    text: 'First sentence. Second sentence, with a clause.',
    maxLength: 30,
    chunks: ['First sentence.', 'Second sentence,', 'with a clause.'],
  ),
  (
    name: 'Latin: falls back to spaces',
    text: 'alpha beta gamma delta epsilon',
    maxLength: 12,
    chunks: ['alpha beta', 'gamma delta', 'epsilon'],
  ),
  (
    name: 'Latin: decimal points are not sentence ends',
    text: 'Pi is 3.14159 and e is 2.71828 roughly',
    maxLength: 20,
    chunks: ['Pi is 3.14159 and e', 'is 2.71828 roughly'],
  ),
  (
    name: 'Latin: closing quotes stay with the full stop',
    text: 'He said "Stop." Then he left the room.',
    maxLength: 20,
    chunks: ['He said "Stop."', 'Then he left the', 'room.'],
  ),
  (
    name: 'Latin: line breaks end sentences',
    text: 'Title\nBody text goes here, and on.',
    maxLength: 20,
    chunks: ['Title', 'Body text goes here,', 'and on.'],
  ),
  (
    name: 'Latin: no-break spaces are kept',
    text: 'Price: 100 000 euros',
    maxLength: 12,
    chunks: ['Price:', '100 000', 'euros'],
  ),
  (
    name: 'Latin: a word longer than the limit is cut by length',
    text: 'a' * 25,
    maxLength: 10,
    chunks: ['a' * 10, 'a' * 10, 'a' * 5],
  ),
  (
    name: 'Latin: breaks right at the limit',
    text: '${'a' * 10} ${'b' * 10}',
    maxLength: 10,
    chunks: ['a' * 10, 'b' * 10],
  ),
  // CJK.
  (
    name: 'Japanese: full stops without spaces',
    text: '今日は晴れです。明日は雨でしょう。週末は分かりません。',
    maxLength: 12,
    chunks: ['今日は晴れです。', '明日は雨でしょう。', '週末は分かりません。'],
  ),
  (
    name: 'Japanese: closing brackets stay with the full stop',
    text: '彼は「行きます。」と言った。それから出かけた。',
    maxLength: 12,
    chunks: ['彼は「行きます。」', 'と言った。', 'それから出かけた。'],
  ),
  (
    name: 'Chinese: commas when a sentence is too long',
    text: '我们今天去公园，然后去超市，最后回家。',
    maxLength: 8,
    chunks: ['我们今天去公园，', '然后去超市，', '最后回家。'],
  ),
  (
    name: 'Chinese: no punctuation is cut by length',
    text: '一二三四五六七八九十',
    maxLength: 4,
    chunks: ['一二三四', '五六七八', '九十'],
  ),
  // Thai.
  (
    name: 'Thai: breaks at the spaces between phrases',
    text: 'สวัสดีครับ ยินดีที่ได้รู้จัก ขอบคุณมาก',
    maxLength: 30,
    chunks: ['สวัสดีครับ ยินดีที่ได้รู้จัก', 'ขอบคุณมาก'],
  ),
  (
    name: 'Thai: never separates vowel and tone marks',
    text: 'ที่' * 5,
    maxLength: 4,
    chunks: ['ที่', 'ที่', 'ที่', 'ที่', 'ที่'],
  ),
  // Emoji.
  (
    name: 'emoji: keeps ZWJ sequences whole',
    text: _family * 5,
    maxLength: 25,
    chunks: [_family * 2, _family * 2, _family],
  ),
  (
    name: 'emoji: keeps flags and skin tones whole',
    text: '🇫🇷🇩🇪👍🏽',
    maxLength: 5,
    chunks: ['🇫🇷', '🇩🇪', '👍🏽'],
  ),
  (
    name: 'emoji: an emoji-only chunk is kept',
    text: 'Great job 👍🏽 see you soon 🎉',
    maxLength: 14,
    chunks: ['Great job 👍🏽', 'see you soon', '🎉'],
  ),
  // Other scripts.
  (
    name: 'Devanagari: danda ends sentences',
    text: 'नमस्ते। आप कैसे हैं',
    maxLength: 10,
    chunks: ['नमस्ते।', 'आप कैसे', 'हैं'],
  ),
  (
    name: 'Arabic: question mark and comma',
    text: 'كيف حالك؟ أنا بخير، شكرا لك',
    maxLength: 12,
    chunks: ['كيف حالك؟', 'أنا بخير،', 'شكرا لك'],
  ),
  // Edge cases.
  (
    name: 'drops chunks with nothing to pronounce',
    text: 'Hi there. ... !!! Bye now',
    maxLength: 10,
    chunks: ['Hi there.', 'Bye now'],
  ),
  (
    name: 'keeps punctuation when nothing else is left',
    text: '?!' * 10,
    maxLength: 10,
    chunks: ['?!' * 5, '?!' * 5],
  ),
  (
    name: 'keeps a grapheme longer than the limit whole',
    text: 'a${'́' * 10} b',
    maxLength: 4,
    chunks: ['a${'́' * 10}', 'b'],
  ),
];

void main() {
  group('splitTextForSpeech', () {
    test('returns short text as one trimmed chunk', () {
      expect(splitTextForSpeech('  Hello world.  \n'), ['Hello world.']);
    });

    test('returns no chunks for blank text', () {
      expect(splitTextForSpeech(''), isEmpty);
      expect(splitTextForSpeech(' \n\t'), isEmpty);
    });

    test('rejects a non-positive limit', () {
      expect(() => splitTextForSpeech('Hi', maxLength: 0), throwsArgumentError);
    });

    for (final c in _cases) {
      test(c.name, () {
        final chunks = splitTextForSpeech(c.text, maxLength: c.maxLength);

        expect(chunks, c.chunks);
        for (final chunk in chunks) {
          if (chunk.characters.length > 1) {
            expect(chunk.length, lessThanOrEqualTo(c.maxLength), reason: chunk);
          }
          expect(_startsWithMark.hasMatch(chunk), isFalse, reason: chunk);
        }
      });
    }

    group('with the default limit', () {
      final latin = List.generate(
        40,
        (i) => 'Sentence number $i is short, but they add up quickly.',
      ).join(' ');
      final chinese = List.filled(80, '这是一个很长的句子，没有空格。').join();
      final thai = List.filled(60, 'ภาษาไทยไม่มีช่องว่างระหว่างคำ').join();
      final emoji = _family * 60;

      for (final (name, text) in [
        ('Latin', latin),
        ('Chinese', chinese),
        ('Thai', thai),
        ('emoji', emoji),
      ]) {
        test('keeps $name request lines well under 4 KiB', () {
          final chunks = splitTextForSpeech(text);

          expect(chunks.length, greaterThan(1));
          for (final chunk in chunks) {
            expect(chunk.length, lessThanOrEqualTo(maxSpeechChunkLength));
            expect(Uri.encodeQueryComponent(chunk).length, lessThan(2000));
          }
          // Nothing is lost: only whitespace between chunks is dropped.
          expect(chunks.join().replaceAll(' ', ''), text.replaceAll(' ', ''));
        });
      }

      test('splits Latin text between sentences', () {
        for (final chunk in splitTextForSpeech(latin)) {
          expect(chunk, startsWith('Sentence'));
          expect(chunk, endsWith('quickly.'));
        }
      });

      test('splits Chinese text after full stops', () {
        for (final chunk in splitTextForSpeech(chinese)) {
          expect(chunk, endsWith('。'));
        }
      });

      test('splits Thai text between grapheme clusters', () {
        final chunks = splitTextForSpeech(thai);

        expect(
          chunks.expand((chunk) => chunk.characters).toList(),
          thai.characters.toList(),
        );
      });
    });
  });

  group('speechChunks', () {
    test('gives each chunk its place in the text as given', () {
      const text = '  One two. Three four.\n\nFive six.  ';
      final chunks = speechChunks(text, maxLength: 12);
      expect(
        [for (final chunk in chunks) chunk.text],
        ['One two.', 'Three four.', 'Five six.'],
      );
      for (final chunk in chunks) {
        expect(text.substring(chunk.start, chunk.end), chunk.text);
      }
      expect(chunks.first.start, 2);
    });

    test('a text that fits is one chunk after its leading space', () {
      expect(speechChunks(' Hi '), [const SpeechChunk(1, 'Hi')]);
      expect(speechChunks('   '), isEmpty);
    });

    test('dropped chunks keep the offsets of the others', () {
      const text = 'Hello there ... ... ... friend';
      final chunks = speechChunks(text, maxLength: 12);
      for (final chunk in chunks) {
        expect(text.substring(chunk.start, chunk.end), chunk.text);
      }
      expect([
        for (final chunk in chunks) chunk.text,
      ], splitTextForSpeech(text, maxLength: 12));
    });

    test('compares chunks by value', () {
      expect(const SpeechChunk(1, 'a'), const SpeechChunk(1, 'a'));
      expect(const SpeechChunk(1, 'a'), isNot(const SpeechChunk(2, 'a')));
      expect(
        const SpeechChunk(1, 'a').hashCode,
        const SpeechChunk(1, 'a').hashCode,
      );
      expect('${const SpeechChunk(1, 'a')}', 'SpeechChunk(1, a)');
    });

    test('rejects a length below one', () {
      expect(() => speechChunks('a', maxLength: 0), throwsArgumentError);
    });
  });
}
