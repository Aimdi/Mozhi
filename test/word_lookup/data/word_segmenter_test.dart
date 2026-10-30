import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/word_lookup/data/word_segmenter.dart';

/// A [WordIndex] of [words], recording what it was asked.
class _SetIndex implements WordIndex {
  new(this.words);

  final Set<String> words;
  final asked = <String>[];

  @override
  Future<bool> contains(String word) async {
    asked.add(word);
    return words.contains(word);
  }

  @override
  Future<bool> hasPrefix(String prefix) async =>
      words.any((word) => word.startsWith(prefix));
}

/// The word of [text] at the first occurrence of [at] (plus [shift]).
String? _wordAt(String text, String at, {int shift = 0}) =>
    WordSegmenter.wordAt(text, text.indexOf(at) + shift)?.text;

Future<String?> _lookUp(
  String text,
  String at, {
  WordIndex? index,
  int shift = 0,
}) async => (await WordSegmenter.lookUpWordAt(
  text,
  text.indexOf(at) + shift,
  index: index,
))?.text;

void main() {
  group('TextWord', () {
    test('compares by value', () {
      expect(const TextWord(1, 3, 'ab'), const TextWord(1, 3, 'ab'));
      expect(const TextWord(1, 3, 'ab'), isNot(const TextWord(0, 2, 'ab')));
      expect(
        const TextWord(1, 3, 'ab').hashCode,
        const TextWord(1, 3, 'ab').hashCode,
      );
      expect('${const TextWord(1, 3, 'ab')}', 'TextWord(1, 3, ab)');
    });
  });

  group('Latin text', () {
    const text = '«Hello,» she said. "Don\'t go!"';

    test('finds the word under the position, punctuation trimmed', () {
      expect(_wordAt(text, 'Hello'), 'Hello');
      expect(_wordAt(text, 'Hello', shift: 3), 'Hello');
      expect(_wordAt(text, 'said'), 'said');
      expect(_wordAt(text, 'go'), 'go');
    });

    test('keeps apostrophes inside words', () {
      expect(_wordAt(text, 'Don'), "Don't");
      expect(_wordAt(text, "'t"), "Don't");
      expect(_wordAt('l’homme est là', 'homme'), 'l’homme');
    });

    test('trims apostrophes and quotes at the ends', () {
      expect(_wordAt("'Tis the dogs' toy", 'Tis'), 'Tis');
      expect(_wordAt("'Tis the dogs' toy", 'dogs'), 'dogs');
    });

    test('a position right after a word finds that word', () {
      final world = WordSegmenter.wordAt('Hello world.', 11);
      expect(world, const TextWord(6, 11, 'world'));
      expect(WordSegmenter.wordAt('Hello world', 11)?.text, 'world');
      expect(WordSegmenter.wordAt('Hello world', 99)?.text, 'world');
    });

    test('nothing on white space, punctuation or digits alone', () {
      expect(WordSegmenter.wordAt('Hello  world', 6), isNull);
      expect(WordSegmenter.wordAt('Wait — what', 5), isNull);
      expect(WordSegmenter.wordAt('In 2026 now', 4), isNull);
      expect(WordSegmenter.wordAt('', 0), isNull);
      expect(WordSegmenter.wordAt('...', 1), isNull);
    });

    test('letters with digits are a word', () {
      expect(_wordAt('a 3D film', '3D'), '3D');
    });

    test('keeps combining accents with their letters', () {
      const decomposed = 'un café noir';
      expect(_wordAt(decomposed, 'caf'), 'café');
    });
  });

  group('compounds', () {
    test('German compounds are one word', () {
      const text = 'Die Donaudampfschifffahrtsgesellschaft fährt.';
      expect(_wordAt(text, 'dampf'), 'Donaudampfschifffahrtsgesellschaft');
      expect(_wordAt(text, 'fährt'), 'fährt');
    });

    test('hyphens join the parts of a word, not a dash between words', () {
      const text = 'Ihre E-Mail-Adresse - bitte';
      expect(_wordAt(text, 'Mail'), 'E-Mail-Adresse');
      expect(_wordAt(text, 'bitte'), 'bitte');
      expect(_wordAt('a well-known fact', 'known'), 'well-known');
      expect(_wordAt('trailing- word', 'trailing'), 'trailing');
    });

    test('the Catalan middle dot joins a word', () {
      expect(_wordAt('una col·lecció nova', 'lecció'), 'col·lecció');
    });
  });

  group('right-to-left text', () {
    test('Arabic words, their marks and punctuation', () {
      const text = 'مرحبا، كَتَبَ الولد';
      expect(_wordAt(text, 'مرحبا'), 'مرحبا');
      expect(_wordAt(text, 'تَ'), 'كَتَبَ');
      expect(_wordAt(text, 'الولد', shift: 2), 'الولد');
    });

    test('Persian keeps the zero-width non-joiner inside a word', () {
      const text = 'من می‌خواهم بروم';
      expect(_wordAt(text, 'خواهم'), 'می‌خواهم');
    });

    test('Hebrew words, gershayim and maqaf', () {
      expect(_wordAt('שלום עולם', 'עולם'), 'עולם');
      expect(_wordAt('חייל בצה״ל היום', 'צה'), 'בצה״ל');
      expect(_wordAt('בית־ספר גדול', 'ספר'), 'בית־ספר');
    });
  });

  group('emoji', () {
    test('an emoji is a word of its own, with its modifiers', () {
      const text = 'I ❤️ Paris👍🏽 and 👨‍👩‍👧!';
      expect(_wordAt(text, '❤️'), '❤️');
      expect(_wordAt(text, 'Paris'), 'Paris');
      expect(_wordAt(text, '👍🏽'), '👍🏽');
      expect(_wordAt(text, '👨‍👩‍👧'), '👨‍👩‍👧');
      expect(_wordAt(text, '👨‍👩‍👧', shift: 3), '👨‍👩‍👧');
    });
  });

  group('scripts without spaces', () {
    final chinese = _SetIndex({'喜欢', '北京', '北京大学', '大学'});
    const sentence = '我喜欢北京大学。';

    test('tells them apart', () {
      expect(WordSegmenter.writtenWithoutSpaces('漢'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('ひ'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('ー'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('ไ'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('ລ'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('ក'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('က'), isTrue);
      expect(WordSegmenter.writtenWithoutSpaces('a'), isFalse);
      expect(WordSegmenter.writtenWithoutSpaces('한'), isFalse);
    });

    test('without a dictionary: one character', () async {
      expect(_wordAt(sentence, '京'), '京');
      expect(await _lookUp(sentence, '京'), '京');
    });

    test('the longest word of the dictionary covering the position', () async {
      expect(await _lookUp(sentence, '北', index: chinese), '北京大学');
      expect(await _lookUp(sentence, '京', index: chinese), '北京大学');
      expect(await _lookUp(sentence, '学', index: chinese), '北京大学');
      expect(await _lookUp(sentence, '喜', index: chinese), '喜欢');
      expect(await _lookUp(sentence, '欢', index: chinese), '喜欢');
    });

    test('one character when the dictionary has no word there', () async {
      expect(await _lookUp(sentence, '我', index: chinese), '我');
    });

    test('punctuation is no word', () async {
      expect(await _lookUp('你好。', '。', index: chinese, shift: 1), isNull);
      expect(await _lookUp('你好 。', ' ', index: chinese), '好');
    });

    test('of two words of equal length, the earlier one', () async {
      final index = _SetIndex({'東京', '京大'});
      expect(await _lookUp('東京大', '京', index: index), '東京');
    });

    test('Japanese mixes kanji and kana in one word', () async {
      final index = _SetIndex({'東京', '行きます', 'コーヒー'});
      const text = '東京に行きます。コーヒーを飲む';
      expect(await _lookUp(text, 'き', index: index), '行きます');
      expect(await _lookUp(text, 'ー', index: index), 'コーヒー');
      expect(await _lookUp(text, 'に', index: index), 'に');
    });

    test('words are at most maxMatchLength characters long', () async {
      final long = '一' * (WordSegmenter.maxMatchLength + 1);
      final index = _SetIndex({long, '一一'});
      expect(await _lookUp(long, '一', index: index), '一一');
    });

    test('never asks for prefixes the dictionary has no word for', () async {
      final index = _SetIndex({'喜欢'});
      await _lookUp(sentence, '京', index: index);
      expect(index.asked, isEmpty);
    });

    test('Thai: the longest word of the dictionary', () async {
      final thai = _SetIndex({'ฉัน', 'รัก', 'ภาษา', 'ไทย', 'ภาษาไทย'});
      const text = 'ฉันรักภาษาไทย';
      expect(await _lookUp(text, 'ษา', index: thai), 'ภาษาไทย');
      expect(await _lookUp(text, 'รัก', shift: 1, index: thai), 'รัก');
      expect(await _lookUp(text, 'ฉัน', index: thai), 'ฉัน');
    });

    test('Thai without a dictionary: one grapheme cluster', () async {
      // ร with its vowel mark above is one cluster.
      expect(await _lookUp('รัก', 'ร'), 'รั');
    });

    test('a word never mixes two scripts', () async {
      final index = _SetIndex({'北京ไทย'});
      expect(await _lookUp('北京ไทย', '京', index: index), '京');
    });

    test('text with spaces next to it is cut at the spaces', () async {
      expect(await _lookUp('Tokyo 東京', 'Tokyo', index: chinese), 'Tokyo');
    });
  });

  group('sentenceAround', () {
    test('the sentence of the word', () {
      const text = 'First one. Second sentence here! Third.';
      final word = WordSegmenter.wordAt(text, text.indexOf('sentence'))!;
      expect(WordSegmenter.sentenceAround(text, word), 'Second sentence here!');
      final first = WordSegmenter.wordAt(text, 1)!;
      expect(WordSegmenter.sentenceAround(text, first), 'First one.');
      final last = WordSegmenter.wordAt(text, text.length - 2)!;
      expect(WordSegmenter.sentenceAround(text, last), 'Third.');
    });

    test('Chinese full stops end sentences', () {
      const text = '你好。我喜欢北京。再见';
      const word = TextWord(6, 8, '北京');
      expect(WordSegmenter.sentenceAround(text, word), '我喜欢北京。');
    });

    test('a long sentence is cut around the word', () {
      final text = '${'a ' * 300}word${' b' * 300}.';
      final start = text.indexOf('word');
      final word = TextWord(start, start + 4, 'word');
      final around = WordSegmenter.sentenceAround(text, word, maxLength: 40);
      expect(around, contains('word'));
      expect(around.length, lessThanOrEqualTo(40));
    });

    test('never cuts a surrogate pair', () {
      final text = '${'😀' * 50}word${'😀' * 50}';
      final start = text.indexOf('word');
      final word = TextWord(start, start + 4, 'word');
      final around = WordSegmenter.sentenceAround(text, word, maxLength: 21);
      expect(around, startsWith('😀'));
      expect(around, endsWith('😀'));
    });
  });
}
