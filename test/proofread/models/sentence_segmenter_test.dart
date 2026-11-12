import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';

/// The sentences of [text] as strings.
List<String> _split(String text) => [
  for (final sentence in SentenceSegmenter.split(text)) sentence.of(text),
];

void main() {
  group('SentenceRange', () {
    test('reads its text and contains its offsets', () {
      const range = SentenceRange(2, 5);
      expect(range.of('a bcd e'), 'bcd');
      expect(range.contains(2), isTrue);
      expect(range.contains(4), isTrue);
      expect(range.contains(5), isFalse);
      expect(range.contains(1), isFalse);
      expect(range, const SentenceRange(2, 5));
      expect(range.toString(), 'SentenceRange(2, 5)');
    });
  });

  group('SentenceSegmenter.split', () {
    test('yields nothing for empty or blank text', () {
      expect(SentenceSegmenter.split(''), isEmpty);
      expect(SentenceSegmenter.split('  \n\t '), isEmpty);
    });

    test('keeps a text without terminal punctuation whole', () {
      expect(_split('  just some words  '), ['just some words']);
    });

    test('splits after full stops, exclamation and question marks', () {
      expect(_split('One. Two! Three? Four'), [
        'One.',
        'Two!',
        'Three?',
        'Four',
      ]);
    });

    test('returns trimmed offsets into the text', () {
      expect(SentenceSegmenter.split('  Hi.  Yes. '), const [
        SentenceRange(2, 5),
        SentenceRange(7, 11),
      ]);
    });

    test('keeps runs of terminals together', () {
      expect(_split('Really?! Yes... Sure‽ Ok…'), [
        'Really?!',
        'Yes...',
        'Sure‽',
        'Ok…',
      ]);
    });

    test('keeps closing quotes and brackets with the sentence', () {
      expect(_split('He said "Go." Then (he left.) «Oui.» Done.'), [
        'He said "Go."',
        'Then (he left.)',
        '«Oui.»',
        'Done.',
      ]);
      expect(_split('She asked “why?” We left.'), [
        'She asked “why?”',
        'We left.',
      ]);
    });

    test('does not split inside numbers, addresses or file names', () {
      expect(_split('Pi is 3.14 today. See example.com or a.txt now.'), [
        'Pi is 3.14 today.',
        'See example.com or a.txt now.',
      ]);
    });

    test('does not split after abbreviations', () {
      expect(_split('Dr. Smith and Mrs. Jones met. They talked.'), [
        'Dr. Smith and Mrs. Jones met.',
        'They talked.',
      ]);
      expect(_split('Use fruit, e.g. Apples. Or i.e. Pears.'), [
        'Use fruit, e.g. Apples.',
        'Or i.e. Pears.',
      ]);
      expect(_split('We met at 9 a.m. Then we ate.'), [
        'We met at 9 a.m. Then we ate.',
      ]);
    });

    test('keeps etc. and usw. with what follows (no fragment)', () {
      expect(_split('Bring pens, paper etc. Markers too. Go.'), [
        'Bring pens, paper etc. Markers too.',
        'Go.',
      ]);
      expect(_split('Äpfel, Birnen usw. Gemüse gab es nicht. Gut.'), [
        'Äpfel, Birnen usw. Gemüse gab es nicht.',
        'Gut.',
      ]);
    });

    group('German abbreviations', () {
      test('does not split at spaced dotted abbreviations', () {
        expect(_split('Obst, z. B. Äpfel, schmeckt gut. Dann gehen wir.'), [
          'Obst, z. B. Äpfel, schmeckt gut.',
          'Dann gehen wir.',
        ]);
        expect(_split('Er kommt, d. h. Sie warten. Gut.'), [
          'Er kommt, d. h. Sie warten.',
          'Gut.',
        ]);
        expect(_split('Es kamen u. a. Anna und Ben. Schön.'), [
          'Es kamen u. a. Anna und Ben.',
          'Schön.',
        ]);
        expect(_split('Das gilt i. d. R. Montags. Sonst nicht.'), [
          'Das gilt i. d. R. Montags.',
          'Sonst nicht.',
        ]);
        expect(_split('Bücher, Hefte o. Ä. Kosten extra. Ok.'), [
          'Bücher, Hefte o. Ä. Kosten extra.',
          'Ok.',
        ]);
      });

      test('does not split at unspaced dotted abbreviations', () {
        expect(_split('Obst, z.B. Äpfel, ist gut. Dann d.h. Birnen. Ja.'), [
          'Obst, z.B. Äpfel, ist gut.',
          'Dann d.h. Birnen.',
          'Ja.',
        ]);
        expect(_split('Sie lebt in den U.S.A. Seit Jahren. Toll.'), [
          'Sie lebt in den U.S.A. Seit Jahren.',
          'Toll.',
        ]);
        expect(_split('Im Jahr 50 v. Chr. Begann es. Dann.'), [
          'Im Jahr 50 v. Chr. Begann es.',
          'Dann.',
        ]);
      });

      test('does not split at single-word abbreviations', () {
        for (final text in [
          'Er wohnt in Nr. 5 hier. Danach.',
          'Es kostet ca. Zehn Euro hier. Danach.',
          'Rot bzw. Blau passt hier. Danach.',
          'Das ist evtl. Unsinn hier. Danach.',
          'Bitte ggf. Rückmeldung geben. Danach.',
        ]) {
          expect(_split(text), hasLength(2), reason: text);
          expect(_split(text).last, 'Danach.', reason: text);
        }
      });

      test('does not split at ordinal numbers and dates', () {
        expect(_split('Wir treffen uns am 3. Oktober in Bonn. Komm mit.'), [
          'Wir treffen uns am 3. Oktober in Bonn.',
          'Komm mit.',
        ]);
        expect(_split('Er belegte den 2. Platz im Rennen. Toll.'), [
          'Er belegte den 2. Platz im Rennen.',
          'Toll.',
        ]);
        expect(_split('Sie wurde der 2. Sieger. Zum 1. Mal! Ja.'), [
          'Sie wurde der 2. Sieger.',
          'Zum 1. Mal!',
          'Ja.',
        ]);
        expect(_split('Vom 1. Mai bis 31. Dez. bleibt es zu. Leider.'), [
          'Vom 1. Mai bis 31. Dez. bleibt es zu.',
          'Leider.',
        ]);
        expect(_split('Am 24. Dezember 2024. Dann kam Silvester.'), [
          'Am 24. Dezember 2024.',
          'Dann kam Silvester.',
        ]);
      });

      test('still splits after a number that ends a sentence', () {
        expect(_split('I am 25. My name is Ann.'), [
          'I am 25.',
          'My name is Ann.',
        ]);
        expect(_split('Wir zählten bis 2024. Dann bis 5. Ende.'), [
          'Wir zählten bis 2024.',
          'Dann bis 5.',
          'Ende.',
        ]);
      });
    });

    test('keeps an English sentence end before a capital', () {
      expect(_split('I like plan b. A new day. See www.example.com. Ok.'), [
        'I like plan b.',
        'A new day.',
        'See www.example.com.',
        'Ok.',
      ]);
    });

    test('does not split before a lower-case word', () {
      expect(_split('Use a tool, approx. as shown. wait... what? Fine.'), [
        'Use a tool, approx. as shown. wait... what?',
        'Fine.',
      ]);
    });

    test('keeps initials with the name', () {
      expect(_split('J. R. R. Tolkien wrote it. Read it.'), [
        'J. R. R. Tolkien wrote it.',
        'Read it.',
      ]);
    });

    test('keeps a list number with its item', () {
      expect(_split('1. First item.\n2. Second item.'), [
        '1. First item.',
        '2. Second item.',
      ]);
      expect(_split('We won 2. Then we lost.'), ['We won 2.', 'Then we lost.']);
    });

    test('ends a sentence at every line break', () {
      expect(_split('Dear Ana,\n\nThanks for this\nBest,\r\nBo'), [
        'Dear Ana,',
        'Thanks for this',
        'Best,',
        'Bo',
      ]);
    });

    test('splits CJK text after full-width terminals without spaces', () {
      expect(_split('今日は晴れです。明日は雨？はい！'), ['今日は晴れです。', '明日は雨？', 'はい！']);
      expect(_split('他说：「好。」我们走吧。'), ['他说：「好。」', '我们走吧。']);
    });

    test('splits other scripts at their full stops', () {
      expect(_split('यह ठीक है। वह भी।'), ['यह ठीक है।', 'वह भी।']);
      expect(_split('هل أنت بخير؟ نعم.'), ['هل أنت بخير؟', 'نعم.']);
    });

    test('splits at the end of the text and before a closing bracket end', () {
      expect(_split('End.'), ['End.']);
      expect(_split('(Yes.)'), ['(Yes.)']);
    });
  });
}
