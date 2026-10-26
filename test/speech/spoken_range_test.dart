import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/speech/spoken_range.dart';

void main() {
  group(SpokenRange, () {
    test('compares by value, shifts and tells empty ranges', () {
      expect(const SpokenRange(1, 3), const SpokenRange(1, 3));
      expect(const SpokenRange(1, 3), isNot(const SpokenRange(1, 4)));
      expect(const SpokenRange(1, 3).shift(10), const SpokenRange(11, 13));
      expect(const SpokenRange(2, 2).isEmpty, isTrue);
      expect(const SpokenRange(2, 3).isEmpty, isFalse);
      expect('${const SpokenRange(1, 3)}', 'SpokenRange(1, 3)');
    });
  });

  group('cleanSpokenRange', () {
    test('keeps a word as reported', () {
      expect(cleanSpokenRange('Hello world', 6, 11), const SpokenRange(6, 11));
      expect(cleanSpokenRange('Hello', 0, 5), const SpokenRange(0, 5));
    });

    test('clamps the offsets to the text', () {
      expect(cleanSpokenRange('Hello world', 6, 99), const SpokenRange(6, 11));
      expect(cleanSpokenRange('Hello world', -3, 5), const SpokenRange(0, 5));
      expect(cleanSpokenRange('Hello', 7, 9), isNull);
      expect(cleanSpokenRange('Hello', 3, 1), isNull);
    });

    test('drops a report of the whole text of several words', () {
      expect(cleanSpokenRange('Hello world', 0, 11), isNull);
      expect(cleanSpokenRange(' Hi ', 0, 4), const SpokenRange(0, 3));
    });

    test('ends a word at a space or punctuation', () {
      expect(cleanSpokenRange('Hello, world', 0, 9), const SpokenRange(0, 5));
      expect(cleanSpokenRange('我们今天去公园。明天', 2, 10), const SpokenRange(2, 7));
      expect(
        cleanSpokenRange('«Bonjour» dit-il', 0, 9),
        const SpokenRange(0, 8),
      );
    });

    test('keeps apostrophes and hyphens inside a word', () {
      expect(cleanSpokenRange("I don't know", 2, 12), const SpokenRange(2, 7));
      expect(cleanSpokenRange('dit-il encore', 0, 10), const SpokenRange(0, 6));
    });

    test('never splits a surrogate pair', () {
      const text = 'a😀 b';
      // The engine ends inside the emoji.
      expect(cleanSpokenRange(text, 1, 2), const SpokenRange(1, 3));
    });

    test('drops ranges with nothing to read', () {
      expect(cleanSpokenRange('Wait... what', 4, 7), isNull);
      expect(cleanSpokenRange('a — b', 2, 3), isNull);
    });
  });
}
