import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/usage/token_estimate.dart';

void main() {
  group('estimateTokensForChars', () {
    test('is zero for zero or negative counts', () {
      expect(estimateTokensForChars(0), 0);
      expect(estimateTokensForChars(-5), 0);
    });

    test('rounds a quarter of the characters up', () {
      expect(estimateTokensForChars(1), 1);
      expect(estimateTokensForChars(4), 1);
      expect(estimateTokensForChars(5), 2);
      expect(estimateTokensForChars(400), 100);
    });
  });

  group('TokenEstimate', () {
    test('of empty text is zero', () {
      const empty = TokenEstimate();
      expect(TokenEstimate.of('').tokens, 0);
      expect(empty.characters, 0);
      expect(empty.tokens, 0);
    });

    test('counts Latin text as chars / 4', () {
      final estimate = TokenEstimate.of('Hello, world!');
      expect(estimate.characters, 13);
      expect(estimate.cjkCharacters, 0);
      expect(estimate.tokens, 4);
    });

    test('counts each CJK character as one token', () {
      expect(estimateTokens('你好世界'), 4);
      expect(estimateTokens('こんにちは'), 5);
      expect(estimateTokens('カタカナ'), 4);
      expect(estimateTokens('안녕하세요'), 5);
      expect(estimateTokens('。、「」'), 4);
      expect(estimateTokens('ＡＢＣ'), 3);
    });

    test('mixes CJK and other scripts', () {
      final estimate = TokenEstimate.of('Hi 你好!');
      expect(estimate.characters, 6);
      expect(estimate.cjkCharacters, 2);
      // 2 CJK + ceil(4 / 4).
      expect(estimate.tokens, 3);
    });

    test('counts code points, not UTF-16 units', () {
      // U+20BB7 (supplementary ideograph) and an emoji.
      final estimate = TokenEstimate.of('\u{20BB7}😀');
      expect(estimate.characters, 2);
      expect(estimate.cjkCharacters, 1);
      expect(estimate.tokens, 2);
    });
  });

  group('isCjkRune', () {
    test('recognises CJK blocks', () {
      for (final rune in [
        0x1100,
        0x2E80,
        0x3000,
        0x3042,
        0x3105,
        0x3400,
        0x4E00,
        0xA960,
        0xAC00,
        0xF900,
        0xFE30,
        0xFF21,
        0x20000,
      ]) {
        expect(isCjkRune(rune), isTrue, reason: rune.toRadixString(16));
      }
    });

    test('rejects other scripts', () {
      for (final rune in 'aZ0 éЖא'.runes) {
        expect(isCjkRune(rune), isFalse, reason: rune.toRadixString(16));
      }
      expect(isCjkRune(0x1F600), isFalse);
    });
  });
}
