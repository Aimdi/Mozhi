import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/practice/data/answer_check.dart';
import 'package:mozhi/practice/data/fsrs.dart';

const AnswerWordStatus _matched = AnswerWordStatus.matched;
const AnswerWordStatus _close = AnswerWordStatus.close;
const AnswerWordStatus _missed = AnswerWordStatus.missed;

List<AnswerWordStatus> _statuses(AnswerCheck check) => [
  for (final word in check.words) word.status,
];

void main() {
  group('answerKeys', () {
    test('ignores case, punctuation and accents', () {
      expect(answerKeys('Où est la gare ?'), ['ou', 'est', 'la', 'gare']);
      expect(answerKeys('¿Dónde está la estación?'), [
        'donde',
        'esta',
        'la',
        'estacion',
      ]);
      expect(answerKeys('Straße'), ['strasse']);
      expect(answerKeys('Ελληνικά'), ['ελληνικα']);
      expect(answerKeys('Tiếng Việt'), ['tieng', 'viet']);
      expect(answerKeys('Ёлка'), ['елка']);
    });

    test('joins apostrophes and splits at other punctuation', () {
      expect(answerKeys("l'eau, s’il vous plaît"), [
        'leau',
        'sil',
        'vous',
        'plait',
      ]);
      expect(answerKeys('dix-sept'), ['dix', 'sept']);
      expect(answerKeys('— ! 🙂'), isEmpty);
    });

    test('drops Arabic vowel marks and Hebrew points', () {
      expect(answerKeys('شُكْرًا'), answerKeys('شكرا'));
      expect(answerKeys('שָׁלוֹם'), answerKeys('שלום'));
    });

    test('keeps the vowel signs of Indian scripts', () {
      expect(answerKeys('नमस्ते'), ['नमस्ते']);
    });

    test('reads number words of the language as digits', () {
      expect(answerKeys('Two coffees', languageCode: 'en'), ['2', 'coffees']);
      expect(answerKeys('dos cafés', languageCode: 'es-419'), ['2', 'cafes']);
      expect(answerKeys('fünf', languageCode: 'de'), ['5']);
      expect(answerKeys('dreißig', languageCode: 'de'), ['30']);
      expect(answerKeys('two', languageCode: 'ja'), ['two']);
      expect(answerKeys('two'), ['two']);
    });

    test('splits Chinese, Japanese and Thai into characters', () {
      expect(answerKeys('谢谢你'), ['谢', '谢', '你']);
      expect(answerKeys('ありがとう。'), ['あ', 'り', 'が', 'と', 'う']);
      expect(answerKeys('Wi-Fi密码'), ['wi', 'fi', '密', '码']);
      expect(answerKeys('ขอบคุณ').length, 6);
    });
  });

  group('checkAnswer', () {
    test('an exact answer matches every word and suggests Good', () {
      final check = checkAnswer(
        expected: 'Onde fica a estação?',
        answer: 'onde fica a estacao',
      );
      expect(_statuses(check), [_matched, _matched, _matched, _matched]);
      expect(check.words.last.text, 'estação?');
      expect(check.isExact, isTrue);
      expect(check.matched, 4);
      expect(check.score, 1);
      expect(check.suggestedRating, FsrsRating.good);
    });

    test('numbers as digits or words match', () {
      final check = checkAnswer(
        expected: 'Two tickets, please',
        answer: '2 tickets please.',
        languageCode: 'en',
      );
      expect(check.isExact, isTrue);
    });

    test('marks missed words and suggests Hard or Again', () {
      final most = checkAnswer(
        expected: 'Where is the train station',
        answer: 'where is train station',
      );
      expect(_statuses(most), [
        _matched,
        _matched,
        _missed,
        _matched,
        _matched,
      ]);
      expect(most.score, closeTo(0.8, 1e-9));
      expect(most.suggestedRating, FsrsRating.hard);

      final little = checkAnswer(
        expected: 'Where is the train station',
        answer: 'the bus',
      );
      expect(little.suggestedRating, FsrsRating.again);
      expect(little.extra, ['bus']);
    });

    test('words a letter off are close', () {
      final check = checkAnswer(
        expected: 'Obrigado pela ajuda',
        answer: 'obrigada pela ajuda',
      );
      expect(_statuses(check), [_close, _matched, _matched]);
      expect(check.score, closeTo(2.5 / 3, 1e-9));
      expect(check.isExact, isFalse);
      // Short words and numbers must be exact.
      expect(_statuses(checkAnswer(expected: 'the cat', answer: 'the cut')), [
        _matched,
        _missed,
      ]);
      expect(_statuses(checkAnswer(expected: '1234', answer: '1235')), [
        _missed,
      ]);
      // Two letters off from 8 letters on.
      expect(
        _statuses(checkAnswer(expected: 'restaurant', answer: 'restorant')),
        [_close],
      );
      expect(_statuses(checkAnswer(expected: 'restaurant', answer: 'rstrnt')), [
        _missed,
      ]);
    });

    test('extra words lower the score', () {
      final check = checkAnswer(
        expected: 'Good morning',
        answer: 'good morning to you all',
      );
      expect(_statuses(check), [_matched, _matched]);
      expect(check.extra, ['to', 'you', 'all']);
      expect(check.score, closeTo(0.4, 1e-9));
      expect(check.isExact, isFalse);
    });

    test('extra words before the phrase are skipped', () {
      final check = checkAnswer(
        expected: 'Good morning',
        answer: 'well good morning',
      );
      expect(_statuses(check), [_matched, _matched]);
      expect(check.extra, ['well']);
    });

    test('a word split by punctuation is close when half of it came out', () {
      final check = checkAnswer(
        expected: 'dix-sept euros',
        answer: 'dix euros',
        languageCode: 'fr',
      );
      expect(_statuses(check), [_close, _matched]);
    });

    test('punctuation alone is left out', () {
      final check = checkAnswer(expected: 'Oui — merci', answer: 'oui merci');
      expect([for (final word in check.words) word.text], ['Oui', 'merci']);
      expect(check.isExact, isTrue);
    });

    test('compares Chinese character by character', () {
      final check = checkAnswer(expected: '谢谢你', answer: '谢谢');
      expect(_statuses(check), [_matched, _matched, _missed]);
    });

    test('nothing expected and nothing said is right', () {
      final check = checkAnswer(expected: '!', answer: '');
      expect(check.words, isEmpty);
      expect(check.score, 1);
      expect(check.suggestedRating, FsrsRating.good);
    });

    test('nothing said misses everything', () {
      final check = checkAnswer(expected: 'Bom dia', answer: '  ');
      expect(_statuses(check), [_missed, _missed]);
      expect(check.score, 0);
      expect(check.suggestedRating, FsrsRating.again);
    });

    test('compares long texts by their beginning', () {
      final long = List.filled(320, 'word').join(' ');
      final check = checkAnswer(expected: long, answer: long);
      expect(check.words.length, 320);
      expect(check.words.last.status, _missed);
      expect(check.words.first.status, _matched);
    });

    test('equal checks are equal', () {
      expect(
        checkAnswer(expected: 'a b', answer: 'a'),
        checkAnswer(expected: 'a b', answer: 'a'),
      );
      expect(const AnswerWord('a', _matched), const AnswerWord('a', _matched));
    });
  });
}
