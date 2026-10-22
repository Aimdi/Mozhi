import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const _en = Language(code: 'en', name: 'English');
const _de = Language(code: 'de', name: 'German');
const _ja = Language(code: 'ja', name: 'Japanese');
const _zh = Language(code: 'zh', name: 'Chinese');
const _ru = Language(code: 'ru', name: 'Russian');

void main() {
  group(TranslationQa, () {
    List<TranslationWarningKind> kinds(
      String source,
      String output, {
      Language from = _en,
      Language to = _de,
      String? detected,
      Map<String, String> glossary = const {},
      bool ai = false,
    }) => [
      for (final warning in TranslationQa.check(
        source: source,
        output: output,
        sourceLanguage: from,
        target: to,
        detectedSource: detected,
        glossary: glossary,
        ai: ai,
      ))
        warning.kind,
    ];

    List<String> items(
      String source,
      String output,
      TranslationWarningKind kind,
    ) => TranslationQa.check(
      source: source,
      output: output,
      sourceLanguage: _en,
      target: _de,
    ).firstWhere((warning) => warning.kind == kind).items;

    test('finds nothing in a faithful translation', () {
      expect(
        kinds(
          'Hello {name}, your order 1,250.50 is at https://x.com/o now.',
          'Hallo {name}, deine Bestellung 1.250,50 ist jetzt bei https://x.com/o.',
        ),
        isEmpty,
      );
    });

    test('checks nothing for blank text', () {
      expect(kinds('', 'x'), isEmpty);
      expect(kinds('x', ' '), isEmpty);
    });

    group('format', () {
      test('placeholders, also masked tokens', () {
        expect(
          items(
            'Hi %s and {name} and {{n}} and ⟨1⟩',
            'Hallo und',
            TranslationWarningKind.placeholders,
          ),
          ['%s', '{name}', '{{n}}', '⟨1⟩'],
        );
        expect(kinds('Hi ⟨ 1 ⟩ there', 'Hallo ⟨1⟩ da'), isEmpty);
      });

      test('a placeholder used twice must come back twice', () {
        expect(
          items('{a} and {a}', '{a} und', TranslationWarningKind.placeholders),
          ['{a}'],
        );
      });

      test('tags by name, attributes may change; entities', () {
        expect(
          kinds('<a title="Hi">x</a> &amp;', '<a title="Hallo">x</a> &amp;'),
          isEmpty,
        );
        expect(
          items(
            '<b>bold</b> &amp; <!-- c -->',
            'fett',
            TranslationWarningKind.markup,
          ),
          ['<b', '</b', '<!-- c -->', '&amp;'],
        );
      });

      test('links and e-mail addresses', () {
        expect(
          items(
            'See https://a.example/x now',
            'Siehe jetzt',
            TranslationWarningKind.links,
          ),
          ['https://a.example/x'],
        );
        expect(kinds('Mail A@B.de', 'Schreib a@b.de'), isEmpty);
        expect(items('Mail a@b.de', 'Schreib', TranslationWarningKind.emails), [
          'a@b.de',
        ]);
      });

      test('numbers: separators, digits of other scripts, reordering', () {
        expect(
          kinds('It costs 1,000.50 dollars', 'Es kostet 1.000,50 Dollar'),
          isEmpty,
        );
        expect(
          kinds(
            'Pay 25 now',
            'ادفع ٢٥ الآن',
            to: const Language(code: 'ar', name: 'Arabic'),
          ),
          isEmpty,
        );
        expect(kinds('At 10.30 sharp', 'Um 10:30 Uhr'), isEmpty);
        // Digits of a block without a known zero are compared as they are.
        expect(kinds('Pay 25 now', 'Zahle \u{1D7D0}\u{1D7D3} jetzt'), [
          TranslationWarningKind.numbers,
        ]);
        expect(kinds('Version 1 of 3', 'Version eins'), isEmpty);
        expect(
          items(
            'Call me in 2026 or 2027',
            'Ruf mich 2026 an',
            TranslationWarningKind.numbers,
          ),
          ['2027'],
        );
        expect(kinds('In 22 days', 'In zweiundzwanzig Tagen'), [
          TranslationWarningKind.numbers,
        ]);
      });

      test('numbers inside links and placeholders are not counted', () {
        expect(
          kinds(
            'See https://a.example/2024 {n1}',
            'Siehe https://a.example/2024 {n1}',
          ),
          isEmpty,
        );
      });
    });

    group('glossary', () {
      test('targets of terms in the input must be in the output', () {
        const glossary = {'server': 'Rechner', 'cloud': 'Wolke', 'unused': 'x'};
        expect(
          TranslationQa.missingGlossaryTargets(
            'The Server is in the cloud.',
            'Der Server ist in der Wolke.',
            glossary,
          ),
          ['Rechner'],
        );
        expect(kinds('The server', 'Der Rechner', glossary: glossary), isEmpty);
      });

      test('accepts an inflected ending of longer terms', () {
        expect(
          TranslationQa.missingGlossaryTargets(
            'two keys',
            'zwei Schlüsseln',
            const {'keys': 'Schlüssel'},
          ),
          isEmpty,
        );
        expect(
          TranslationQa.missingGlossaryTargets(
            'two keys',
            'zwei Schlüsseln',
            const {'keys': 'Schlüsselbund'},
          ),
          ['Schlüsselbund'],
        );
        expect(
          TranslationQa.missingGlossaryTargets('a b', 'c', const {
            ' ': 'x',
            'a': ' ',
          }),
          isEmpty,
        );
        expect(
          TranslationQa.missingGlossaryTargets('a', 'b', const {}),
          isEmpty,
        );
      });
    });

    group('suspects', () {
      const prose = 'The weather is nice today and we go out.';

      test('an echo of an explicit other language', () {
        expect(kinds(prose, prose), [TranslationWarningKind.echo]);
        expect(
          kinds(prose, prose.toUpperCase()),
          contains(TranslationWarningKind.echo),
        );
        expect(
          kinds(
            prose,
            prose,
            from: _de,
            to: const Language(code: 'de-AT', name: 'German'),
          ),
          isEmpty,
        );
      });

      test('an echo with a detected source', () {
        expect(kinds(prose, prose, from: Language.auto, detected: 'en'), [
          TranslationWarningKind.echo,
        ]);
        expect(
          kinds(prose, prose, from: Language.auto, detected: 'de'),
          isEmpty,
        );
      });

      test('an echo without a known source, by script', () {
        const russian = 'Сегодня хорошая погода и мы идём гулять.';
        expect(kinds(russian, russian, from: Language.auto), [
          TranslationWarningKind.echo,
        ]);
        expect(kinds(prose, prose, from: Language.auto), isEmpty);
        expect(
          kinds(
            prose,
            prose,
            from: Language.auto,
            to: const Language(code: 'xx-unknown', name: 'X'),
          ),
          isEmpty,
        );
      });

      test('never for custom targets or custom sources', () {
        expect(
          kinds(prose, prose, to: const Language.custom('Pirate')),
          isEmpty,
        );
        expect(
          kinds(prose, prose, from: const Language.custom('Pirate')),
          isEmpty,
        );
      });

      test('the wrong script for the target', () {
        expect(kinds(prose, 'Сегодня хорошая погода и мы идём гулять.'), [
          TranslationWarningKind.wrongLanguage,
        ]);
        expect(kinds(prose, '今日はいい天気なので出かけます。', to: _ja), isEmpty);
        expect(kinds(prose, '今天天气很好，我们出去。', to: _zh), isEmpty);
        expect(
          kinds(prose, 'The weather is nice today, so we go out.', to: _ja),
          [TranslationWarningKind.wrongLanguage],
        );
        expect(kinds(prose, 'Погода хорошая', to: _ru), isEmpty);
        // Too few letters to tell.
        expect(
          kinds(prose, 'OK 123', to: _ja),
          isNot(contains(TranslationWarningKind.wrongLanguage)),
        );
      });

      test('an extreme length', () {
        expect(kinds(prose, 'Gut.'), [TranslationWarningKind.length]);
        expect(
          kinds(prose, List.filled(30, 'Das Wetter ist schön.').join(' ')),
          [TranslationWarningKind.length],
        );
        // CJK characters weigh more.
        expect(kinds(prose, '今日は晴れ。', to: _ja), isEmpty);
        // Short input is not length-checked.
        expect(
          kinds(
            'We go out now',
            'Wir gehen jetzt sofort mit allen Freunden zusammen raus',
          ),
          isEmpty,
        );
      });

      test('skips short input, input without letters and names', () {
        expect(TranslationQa.checksSuspects('Hello there friend'), isFalse);
        expect(TranslationQa.checksSuspects('12 34 56 78 90'), isFalse);
        expect(TranslationQa.checksSuspects('iPhone 15 Pro Max'), isFalse);
        expect(
          TranslationQa.checksSuspects(
            'Visit https://a.example/x and https://b.example',
          ),
          isFalse,
        );
        expect(TranslationQa.checksSuspects(prose), isTrue);
        expect(TranslationQa.checksSuspects('東京 大阪 京都 名古屋'), isTrue);
        expect(
          kinds('iPhone 15 Pro Max', 'iPhone 15 Pro Max', to: _ja),
          isEmpty,
        );
      });
    });

    group('replies (AI only)', () {
      const source = 'Please translate this sentence for the meeting.';

      test('chat openings', () {
        for (final output in [
          'Sure! Here is the translation: Bitte übersetze diesen Satz.',
          'Certainly, I can help with that sentence for the meeting.',
          "Here's the German translation: Bitte übersetze diesen Satz.",
          'As an AI language model, I cannot attend meetings.',
          "I'm sorry, but I cannot translate that for the meeting.",
          "I can't help with this request for the meeting today.",
          'Claro, aquí está la traducción de esta frase para la reunión.',
        ]) {
          expect(
            kinds(source, output, ai: true),
            contains(TranslationWarningKind.notATranslation),
            reason: output,
          );
          expect(
            kinds(source, output),
            isNot(contains(TranslationWarningKind.notATranslation)),
          );
        }
      });

      test('not when the source starts the same way', () {
        expect(
          kinds(
            'Sure, I will come to the meeting tomorrow.',
            'Sure, I will come.',
            from: _de,
            to: _en,
            ai: true,
          ),
          isNot(contains(TranslationWarningKind.notATranslation)),
        );
      });

      test('an answered question', () {
        const question = 'What is the capital city of France, do you know?';
        expect(
          kinds(
            question,
            'The capital of France is Paris. It has been the capital since '
            'the Middle Ages and is the largest city of the country.',
            to: _en,
            from: _de,
            ai: true,
          ),
          contains(TranslationWarningKind.notATranslation),
        );
        expect(
          kinds(
            question,
            'Was ist die Hauptstadt von Frankreich, weißt du das?',
            ai: true,
          ),
          isEmpty,
        );
      });
    });

    test('worthRetrying ignores numbers only', () {
      expect(
        TranslationQa.worthRetrying(const [
          TranslationWarning(TranslationWarningKind.numbers),
        ]),
        isFalse,
      );
      expect(
        TranslationQa.worthRetrying(const [
          TranslationWarning(TranslationWarningKind.links),
        ]),
        isTrue,
      );
      expect(TranslationQa.worthRetrying(const []), isFalse);
    });

    test('correctiveNote names the problems, not the text', () {
      final note = TranslationQa.correctiveNote([
        for (final kind in TranslationWarningKind.values)
          TranslationWarning(kind, items: const ['secret@mail.example']),
      ], target: _de);
      expect(note, contains('into German'));
      expect(note, contains('placeholders or ⟨n⟩ tokens were lost or changed'));
      expect(note, contains('it answers or comments instead of translating'));
      expect(note, isNot(contains('secret@mail.example')));
      expect(
        TranslationQa.correctiveNote(const [
          TranslationWarning(TranslationWarningKind.echo),
        ], target: const Language.custom('Pirate')),
        contains('into the requested style'),
      );
    });

    test('lists at most maxItems items', () {
      final source = List.generate(8, (i) => '{p$i}').join(' ');
      expect(
        items(source, 'x', TranslationWarningKind.placeholders),
        hasLength(TranslationQa.maxItems),
      );
    });
  });
}
