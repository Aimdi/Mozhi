import 'package:test/test.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';

void main() {
  group('TranslationPrompts.glossaryMatches', () {
    /// The terms of [terms] that occur in [text].
    List<String> matches(List<String> terms, String text) =>
        TranslationPrompts.glossaryMatches({
          for (final term in terms) term: 'x',
        }, text).keys.toList();

    bool occurs(String term, String text) => matches([term], text).isNotEmpty;

    group('English', () {
      test('matches whole words, not parts of words', () {
        expect(occurs('cat', 'The cat sat.'), isTrue);
        expect(occurs('cat', 'A new category.'), isFalse);
        expect(occurs('cat', 'Concatenate it.'), isFalse);
        expect(occurs('art', 'Start the party.'), isFalse);
        expect(occurs('art', 'Modern art.'), isTrue);
      });

      test('ignores case and accents', () {
        expect(occurs('Cloud', 'The CLOUD is down.'), isTrue);
        expect(occurs('cafe', 'Meet me at the Café.'), isTrue);
        expect(occurs('Café', 'meet me at the cafe'), isTrue);
      });

      test('matches plurals and inflections', () {
        expect(occurs('cat', 'Two cats.'), isTrue);
        expect(occurs('box', 'Some boxes.'), isTrue);
        expect(occurs('server', 'The servers are down.'), isTrue);
        expect(occurs('deploy', 'We are deploying.'), isTrue);
        // Up to four more letters for a four-letter term (a few false
        // positives are cheap: they only add a glossary line).
        expect(occurs('line', 'A lineage.'), isTrue);
        expect(occurs('line', 'Linearisation.'), isFalse);
      });

      test('matches phrases across any whitespace', () {
        expect(occurs('machine learning', 'Machine\n  learning is.'), isTrue);
        expect(occurs('machine learning', 'machine-learning'), isFalse);
        expect(occurs('pull request', 'two pull requests'), isTrue);
        expect(occurs('pull request', 'pull the request'), isFalse);
      });

      test('matches terms with symbols and digits exactly', () {
        expect(occurs('C++', 'Written in C++ mostly.'), isTrue);
        expect(occurs('C++', 'Written in C++11.'), isFalse);
        expect(occurs('Node.js', 'Runs on node.js.'), isTrue);
        expect(occurs('4K', 'A 4K screen.'), isTrue);
        expect(occurs('4K', 'A 4Ks screen.'), isFalse);
        expect(occurs('(beta)', 'Version 2 (beta) is out.'), isTrue);
        expect(occurs('e-mail', 'Send an e-mail.'), isTrue);
        expect(occurs('e-mail', 'Send an email.'), isFalse);
      });

      test('words next to punctuation and apostrophes', () {
        expect(occurs('server', '"server", she said'), isTrue);
        expect(occurs('ordinateur', "L'ordinateur est lent."), isTrue);
        expect(occurs('Mozhi', "Mozhi's settings"), isTrue);
      });
    });

    group('German', () {
      test('matches inflected nouns, umlaut plurals included', () {
        expect(occurs('Haus', 'Zwei Häuser stehen leer.'), isTrue);
        expect(occurs('Haus', 'Des Hauses Tür.'), isTrue);
        expect(occurs('Garten', 'In den Gärten.'), isTrue);
        expect(occurs('Vogel', 'Viele Vögel.'), isTrue);
        expect(occurs('Mutter', 'Die Mütter kommen.'), isTrue);
      });

      test('does not match longer words or compounds', () {
        expect(occurs('Haus', 'Das Hauptgebäude.'), isFalse);
        expect(occurs('Server', 'Der Webserver läuft.'), isFalse);
        expect(occurs('Rat', 'Die Ratschläge.'), isFalse);
      });
    });

    group('Russian', () {
      test('matches case forms', () {
        expect(occurs('книга', 'Я читаю книгу.'), isTrue);
        expect(occurs('книга', 'Нет книги.'), isTrue);
        expect(occurs('книга', 'С книгой.'), isTrue);
        expect(occurs('сервер', 'Проблема с сервером.'), isTrue);
        expect(occurs('Москва', 'Мы были в Москве.'), isTrue);
        expect(occurs('берёза', 'Под березой.'), isTrue);
      });

      test('does not match other words', () {
        expect(occurs('кот', 'Который час?'), isFalse);
        expect(occurs('книга', 'Книжный магазин.'), isFalse);
      });
    });

    group('Polish', () {
      test('matches case forms', () {
        expect(occurs('Warszawa', 'Mieszkam w Warszawie.'), isTrue);
        expect(occurs('kobieta', 'Dwie kobiety.'), isTrue);
        expect(occurs('Kraków', 'Jadę do Krakowa.'), isTrue);
        expect(occurs('Kowalski', 'U pana Kowalskiego.'), isTrue);
        expect(occurs('łódź', 'Płyniemy łodzią.'), isTrue);
        expect(occurs('kot', 'Kotlet schabowy.'), isFalse);
      });
    });

    group('CJK, Thai', () {
      test('matches anywhere: no spaces between words', () {
        expect(occurs('服务器', '这台服务器坏了。'), isTrue);
        expect(occurs('サーバー', 'サーバーが落ちた。'), isTrue);
        expect(occurs('서버', '서버가 다운됐다.'), isTrue);
        expect(occurs('เซิร์ฟเวอร์', 'เซิร์ฟเวอร์ล่ม'), isTrue);
        expect(occurs('服务器', '这台电脑坏了。'), isFalse);
      });

      test('a mixed term with CJK characters matches anywhere', () {
        expect(occurs('Mozhi翻译', '我用Mozhi翻译。'), isTrue);
      });
    });

    test('keeps the order and renderings, one line each', () {
      expect(
        TranslationPrompts.glossaryMatches({
          'cloud': 'nuage',
          ' server\n': ' serveur ',
          'database': 'base',
          '': 'empty',
          'blank': ' ',
        }, 'Server and cloud and blank.'),
        {'cloud': 'nuage', 'server': 'serveur'},
      );
      expect(TranslationPrompts.glossaryMatches(const {}, 'text'), isEmpty);
    });

    test('blank terms never match', () {
      expect(
        TranslationPrompts.glossaryMatches({'\u200B': 'x'}, 'any text'),
        isEmpty,
      );
      // Nothing is left of a lone combining accent once folded.
      expect(
        TranslationPrompts.glossaryMatches({'\u0301': 'x'}, 'cafe\u0301'),
        isEmpty,
      );
    });

    test('reuses compiled patterns across many terms', () {
      final glossary = {for (var i = 0; i < 5000; i++) 'term$i': 'x$i'};
      final found = TranslationPrompts.glossaryMatches(glossary, 'A term42.');
      expect(found, {'term42': 'x42'});
      expect(TranslationPrompts.glossaryMatches(glossary, 'term4999'), {
        'term4999': 'x4999',
      });
    });
  });

  group('TranslationPrompts.foldForMatching', () {
    test('lower-cases and removes accents', () {
      expect(TranslationPrompts.foldForMatching('HÄUSER'), 'hauser');
      expect(TranslationPrompts.foldForMatching('Kraków Łódź'), 'krakow lodz');
      expect(TranslationPrompts.foldForMatching('Ёлка'), 'елка');
      // Combining marks (decomposed accents) are dropped.
      expect(TranslationPrompts.foldForMatching('Café'), 'cafe');
      expect(TranslationPrompts.foldForMatching('服务器'), '服务器');
    });
  });
}
