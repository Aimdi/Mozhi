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

      test('matches acronyms only in their exact case', () {
        expect(occurs('IT', 'Is it ready?'), isFalse);
        expect(occurs('IT', 'Ask the IT department.'), isTrue);
        expect(occurs('US', 'Tell us more.'), isFalse);
        expect(occurs('US', 'Made in the US.'), isTrue);
        expect(occurs('NASA', 'Nasa is no acronym here.'), isFalse);
        expect(occurs('NASA', "NASA's rocket"), isTrue);
      });

      test('matches case-sensitive terms only in their exact case', () {
        bool exact(String term, String text) =>
            TranslationPrompts.glossaryMatches(
              {term: 'x'},
              text,
              caseSensitive: {term},
            ).isNotEmpty;
        expect(exact('Apple', 'An apple a day.'), isFalse);
        expect(exact('Apple', 'Apple shares rose.'), isTrue);
        expect(exact('Apple', 'APPLE SHARES'), isFalse);
        // Without the flag, case does not matter.
        expect(occurs('Apple', 'An apple a day.'), isTrue);
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

  group('TranslationPrompts.glossaryOccurrences', () {
    /// The occurrences of [glossary] in [text], as `found -> rendering`.
    List<String> found(Map<String, String> glossary, String text) => [
      for (final o in TranslationPrompts.glossaryOccurrences(glossary, text))
        '${text.substring(o.start, o.end)} -> ${o.rendering}',
    ];

    test('finds every occurrence in any case, with a plural s or es', () {
      expect(
        found({'Haus': 'house'}, 'Das Haus, des Hauses, die Häuser, HAUS.'),
        ['Haus -> house', 'Hauses -> house', 'HAUS -> house'],
      );
      expect(found({'server': 'serveur'}, 'Two servers, one Server.'), [
        'servers -> serveur',
        'Server -> serveur',
      ]);
      expect(found({'class': 'classe'}, 'All classes.'), ['classes -> classe']);
      // Terms of at most three letters get no ending.
      expect(found({'cat': 'Katze'}, 'Cats and a category'), isEmpty);
      expect(found({'cat': 'Katze'}, 'A cat, a CAT.'), [
        'cat -> Katze',
        'CAT -> Katze',
      ]);
    });

    group('matches strictly', () {
      test('acronyms: exact case only, no ending', () {
        expect(found({'IT': 'TI'}, 'Is it ready? It is.'), isEmpty);
        expect(found({'IT': 'TI'}, 'The IT department'), ['IT -> TI']);
        expect(found({'IT': 'TI'}, 'ITs and ITEMS'), isEmpty);
        expect(found({'US': 'EE. UU.'}, 'Tell us more, Us two.'), isEmpty);
        expect(found({'US': 'EE. UU.'}, 'The US economy'), ['US -> EE. UU.']);
        expect(found({'EU': 'UE'}, 'EU law, eu, Europe'), ['EU -> UE']);
        expect(found({'B2B': 'B2B'}, 'b2b and B2B'), ['B2B -> B2B']);
      });

      test('whole words: no word that merely starts with the term', () {
        expect(found({'Apple': 'Apple'}, 'He applied for it.'), isEmpty);
        expect(found({'Paris': 'París'}, 'Parity in the parish.'), isEmpty);
        expect(found({'car': 'coche'}, 'He cares for cars.'), isEmpty);
        expect(found({'Mail': 'correo'}, 'Ich fahre nach Mailand.'), isEmpty);
        expect(found({'Bank': 'banco'}, 'Ein Bankett.'), isEmpty);
        expect(found({'art': 'arte'}, 'Start the party.'), isEmpty);
        expect(found({'line': 'línea'}, 'A lineage.'), isEmpty);
      });

      test('ignores the case of other terms', () {
        expect(
          found({'glossary': 'glosario'}, 'Glossary: the glossary, GLOSSARY'),
          [
            'Glossary -> glosario',
            'glossary -> glosario',
            'GLOSSARY -> glosario',
          ],
        );
        expect(found({'Paris': 'París'}, 'paris, Paris and PARIS.'), [
          'paris -> París',
          'Paris -> París',
          'PARIS -> París',
        ]);
        expect(found({'Apple': 'Apple'}, 'An apple, two Apples.'), [
          'apple -> Apple',
          'Apples -> Apple',
        ]);
      });

      test('case-sensitive terms: exact case, a lower-case ending', () {
        List<String> exact(String text) => [
          for (final o in TranslationPrompts.glossaryOccurrences(
            {'Apple': 'Apple Inc.'},
            text,
            caseSensitive: {'Apple'},
          ))
            text.substring(o.start, o.end),
        ];
        expect(exact('An apple, Apple, Apples, APPLE, APPLEs'), [
          'Apple',
          'Apples',
        ]);
      });

      test('phrases, possessives and terms with symbols', () {
        expect(
          found(
            {'machine learning': 'ML'},
            'Machine\n  learning and '
            'machine-learning',
          ),
          ['Machine\n  learning -> ML'],
        );
        expect(found({'pull request': 'PR'}, 'two pull requests'), [
          'pull requests -> PR',
        ]);
        expect(found({'Mozhi': 'Mozhi'}, "Mozhi's settings"), [
          'Mozhi -> Mozhi',
        ]);
        expect(found({'C++': 'C++'}, 'C++ and C++11'), ['C++ -> C++']);
        expect(found({'Node.js': 'Node'}, 'Runs on node.js.'), [
          'node.js -> Node',
        ]);
        expect(found({'4K': '4K'}, 'A 4K screen, 4Ks'), ['4K -> 4K']);
      });

      test('accents must agree; decomposed ones are the same', () {
        expect(found({'té': 'tea'}, 'Te quiero. Un té.'), ['té -> tea']);
        expect(found({'résumé': 'CV'}, 'Resume the résumé.'), ['résumé -> CV']);
        expect(found({'resume': 'reprendre'}, 'Resume the résumé.'), [
          'Resume -> reprendre',
        ]);
        expect(found({'año': 'year'}, 'Un ano, un año'), ['año -> year']);
        expect(found({'café': 'x'}, 'Cafe\u0301 or cafe'), ['Cafe\u0301 -> x']);
        expect(found({'cafe\u0301': 'x'}, 'café or cafe'), ['café -> x']);
        // Russian ё is often written as е.
        expect(found({'берёза': 'birch'}, 'береза, берёза, бере\u0308за'), [
          'береза -> birch',
          'берёза -> birch',
          'бере\u0308за -> birch',
        ]);
      });

      test('is what glossaryMatches finds, minus its lenient guesses', () {
        const glossary = {'Haus': 'house', 'IT': 'TI', 'Kraków': 'Cracow'};
        const text = 'Häuser in Krakowie, it';
        expect(TranslationPrompts.glossaryMatches(glossary, text).keys, [
          'Haus',
          'Kraków',
        ]);
        expect(found(glossary, text), isEmpty);
      });
    });

    test('places longer terms first and never overlaps', () {
      final occurrences = TranslationPrompts.glossaryOccurrences({
        'New York': 'NY',
        'New York Times': 'NYT',
        'York': 'Y',
      }, 'The New York Times in New  York.');
      expect(
        [for (final o in occurrences) (o.start, o.end, o.term)],
        [(4, 18, 'New York Times'), (22, 31, 'New York')],
      );
    });

    test('keeps combining marks and astral characters in the range', () {
      // "Cafe\u0301" folds to "cafe"; the emoji takes two code units.
      const text = '😀 Cafe\u0301 ok';
      expect(found({'café': 'coffee shop'}, text), [
        'Cafe\u0301 -> coffee shop',
      ]);
    });

    test('finds terms of scripts without spaces anywhere', () {
      expect(found({'東京': 'Tokyo'}, '我住在東京，東京很大'), [
        '東京 -> Tokyo',
        '東京 -> Tokyo',
      ]);
    });

    test('skips blank entries and empty texts', () {
      expect(found({' ': 'x', 'a': ' '}, 'a b'), isEmpty);
      expect(found({'cat': 'Katze'}, ''), isEmpty);
      expect(found(const {}, 'cat'), isEmpty);
    });
  });
}
