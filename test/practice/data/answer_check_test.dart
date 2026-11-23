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

    test('parses multi-word compound numbers across supported languages', () {
      // English
      expect(answerKeys('twenty one', languageCode: 'en'), ['21']);
      expect(answerKeys('twenty-one', languageCode: 'en'), ['21']);
      expect(answerKeys('one hundred twenty three', languageCode: 'en'), [
        '123',
      ]);
      expect(answerKeys('one hundred and five', languageCode: 'en'), ['105']);
      expect(answerKeys('two thousand twenty six', languageCode: 'en'), [
        '2026',
      ]);
      expect(answerKeys('two thousand and twenty-six', languageCode: 'en-US'), [
        '2026',
      ]);
      expect(answerKeys('one hundred thousand', languageCode: 'en'), [
        '100000',
      ]);

      // Spanish
      expect(answerKeys('treinta y cinco', languageCode: 'es'), ['35']);
      expect(answerKeys('veintiuno', languageCode: 'es'), ['21']);
      expect(answerKeys('ciento veinte', languageCode: 'es'), ['120']);
      expect(answerKeys('doscientos tres', languageCode: 'es'), ['203']);
      expect(answerKeys('dos mil veintiséis', languageCode: 'es'), ['2026']);
      expect(
        answerKeys('mil novecientos noventa y nueve', languageCode: 'es'),
        ['1999'],
      );

      // French
      expect(answerKeys('vingt et un', languageCode: 'fr'), ['21']);
      expect(answerKeys('quatre-vingt-dix-neuf', languageCode: 'fr'), ['99']);
      expect(answerKeys('soixante-dix', languageCode: 'fr'), ['70']);
      expect(answerKeys('soixante et onze', languageCode: 'fr'), ['71']);
      expect(answerKeys('dix-sept', languageCode: 'fr'), ['17']);
      expect(answerKeys('deux cent cinquante', languageCode: 'fr'), ['250']);
      expect(answerKeys('deux mille vingt-six', languageCode: 'fr'), ['2026']);

      // German
      expect(answerKeys('einundzwanzig', languageCode: 'de'), ['21']);
      expect(answerKeys('ein und zwanzig', languageCode: 'de'), ['21']);
      expect(answerKeys('zweihundert drei', languageCode: 'de'), ['203']);
      expect(answerKeys('dreiundvierzig', languageCode: 'de'), ['43']);
      expect(answerKeys('zweitausendsechsundzwanzig', languageCode: 'de'), [
        '2026',
      ]);

      // Italian
      expect(answerKeys('ventuno', languageCode: 'it'), ['21']);
      expect(answerKeys('ventidue', languageCode: 'it'), ['22']);
      expect(answerKeys('cento venti', languageCode: 'it'), ['120']);
      expect(answerKeys('trecento cinque', languageCode: 'it'), ['305']);
      expect(answerKeys('trecentocinque', languageCode: 'it'), ['305']);
      expect(answerKeys('duemila ventisei', languageCode: 'it'), ['2026']);
      expect(answerKeys('centottanta', languageCode: 'it'), ['180']);

      // Portuguese
      expect(answerKeys('vinte e um', languageCode: 'pt'), ['21']);
      expect(answerKeys('trinta e dois', languageCode: 'pt-BR'), ['32']);
      expect(answerKeys('cento e vinte', languageCode: 'pt'), ['120']);
      expect(answerKeys('duzentos e três', languageCode: 'pt'), ['203']);
      expect(answerKeys('dois mil e vinte e seis', languageCode: 'pt'), [
        '2026',
      ]);

      // Dutch
      expect(answerKeys('eenentwintig', languageCode: 'nl'), ['21']);
      expect(answerKeys('tweeëntwintig', languageCode: 'nl'), ['22']);
      expect(answerKeys('twee en dertig', languageCode: 'nl'), ['32']);
      expect(answerKeys('honderd vijf', languageCode: 'nl'), ['105']);
      expect(answerKeys('tweehonderd vijf', languageCode: 'nl'), ['205']);
    });

    test('does not collapse non-numbers, separate numbers, or pauses', () {
      // Non-number words like "a", "in", conjunctions, and ordinary words.
      expect(answerKeys('a cat in a hat', languageCode: 'en'), [
        'a',
        'cat',
        'in',
        'a',
        'hat',
      ]);
      expect(answerKeys('one and a half', languageCode: 'en'), [
        '1',
        'and',
        'a',
        'half',
      ]);
      expect(answerKeys('two and three', languageCode: 'en'), [
        '2',
        'and',
        '3',
      ]);
      expect(answerKeys('one hundred and', languageCode: 'en'), ['100', 'and']);
      expect(answerKeys('einkaufen und reden', languageCode: 'de'), [
        'einkaufen',
        'und',
        'reden',
      ]);
      expect(answerKeys('zwei und drei', languageCode: 'de'), [
        '2',
        'und',
        '3',
      ]);
      expect(answerKeys('eenheid en brood', languageCode: 'nl'), [
        'eenheid',
        'en',
        'brood',
      ]);
      expect(answerKeys('twee en drie', languageCode: 'nl'), ['2', 'en', '3']);
      expect(answerKeys('ventre ottobre', languageCode: 'it'), [
        'ventre',
        'ottobre',
      ]);
      expect(answerKeys('un et deux', languageCode: 'fr'), ['1', 'et', '2']);

      // Adjacent separate numbers stay separate.
      expect(answerKeys('one two three', languageCode: 'en'), ['1', '2', '3']);
      expect(answerKeys('twenty one twenty two', languageCode: 'en'), [
        '21',
        '22',
      ]);
      expect(answerKeys('one hundred two hundred', languageCode: 'en'), [
        '100',
        '200',
      ]);

      // Clause punctuation stops compounding; surrounding punctuation does not.
      expect(answerKeys('twenty, one', languageCode: 'en'), ['20', '1']);
      expect(answerKeys('(twenty one) apples.', languageCode: 'en'), [
        '21',
        'apples',
      ]);
      expect(answerKeys('It costs twenty one.', languageCode: 'en'), [
        'it',
        'costs',
        '21',
      ]);
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

    test('compound numbers match digits and highlight every display word', () {
      final wordsToDigits = checkAnswer(
        expected: 'I need one hundred and five euros.',
        answer: 'I need 105 euros',
        languageCode: 'en',
      );
      expect(wordsToDigits.isExact, isTrue);
      expect(
        [for (final w in wordsToDigits.words) w.text],
        ['I', 'need', 'one', 'hundred', 'and', 'five', 'euros.'],
      );
      expect(_statuses(wordsToDigits), List.filled(7, _matched));

      final digitsToWords = checkAnswer(
        expected: 'It costs 99 euros',
        answer: 'It costs quatre-vingt-dix-neuf euros',
        languageCode: 'fr',
      );
      expect(digitsToWords.isExact, isTrue);
      expect(digitsToWords.extra, isEmpty);

      final frDixSept = checkAnswer(
        expected: 'dix-sept euros',
        answer: '17 euros',
        languageCode: 'fr',
      );
      expect(frDixSept.isExact, isTrue);

      final wrongCompound = checkAnswer(
        expected: 'twenty one apples',
        answer: 'thirty apples',
        languageCode: 'en',
      );
      expect(_statuses(wrongCompound), [_missed, _missed, _matched]);
      expect(wrongCompound.extra, ['thirty']);

      final extraCompound = checkAnswer(
        expected: 'apples',
        answer: 'twenty one apples',
        languageCode: 'en',
      );
      expect(_statuses(extraCompound), [_matched]);
      expect(extraCompound.extra, ['twenty', 'one']);
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
        expected: 'rendez-vous demain',
        answer: 'rendez demain',
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
