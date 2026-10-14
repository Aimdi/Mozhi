import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/proofread/models/writing_stats.dart';

void main() {
  group('WritingStats.of', () {
    test('is empty for blank text but counts its characters', () {
      expect(WritingStats.of(''), const WritingStats());
      final blank = WritingStats.of('  \n', languageCode: 'en');
      expect(blank.characters, 3);
      expect(blank.words, 0);
      expect(blank.sentences, 0);
      expect(blank.paragraphs, 0);
      expect(blank.readingTime, Duration.zero);
      expect(blank.fleschReadingEase, isNull);
      expect(blank.averageSentenceLength, 0);
      expect(blank.fleschBand, isNull);
    });

    test('counts words, sentences, paragraphs and characters', () {
      final stats = WritingStats.of(
        'The quick brown fox jumps over the lazy dog. It was a sunny day.',
      );
      expect(stats.words, 14);
      expect(stats.sentences, 2);
      expect(stats.paragraphs, 1);
      expect(stats.characters, 64);
      expect(stats.averageSentenceLength, 7);
    });

    group('words', () {
      test('joins apostrophes, hyphens and number separators', () {
        expect(
          WritingStats.of("don't well-known 1,000 10:30 3.14 l’été").words,
          6,
        );
      });

      test('splits words joined by other punctuation', () {
        expect(WritingStats.of('end.Start and/or (yes)').words, 5);
      });

      test('ignores punctuation, symbols and emoji', () {
        expect(WritingStats.of('— … 👍 & * ---').words, 0);
        expect(WritingStats.of('Great job 🎉🎉🎉').words, 2);
        final emoji = WritingStats.of('🎉🎉\nGreat job');
        expect(emoji.paragraphs, 1);
        expect(emoji.sentences, 1);
      });

      test('counts dotted abbreviations as one word', () {
        expect(WritingStats.of('Use tools, e.g. hammers. Then stop.').words, 6);
        expect(WritingStats.of('We met at 10 a.m. on Monday.').words, 7);
        expect(WritingStats.of('i.e. U.S.A.').words, 2);
        // Not a dotted abbreviation: a missing space after a full stop.
        expect(WritingStats.of('a.Start end.b').words, 4);
      });

      group('in scripts without spaces between words', () {
        // Estimated from the letters of each run (see WritingStats.of); the
        // comments give the words that ICU's dictionaries find.
        test('estimates Thai words', () {
          // ICU: ผม|ชอบ|กิน|ข้าว|ผัด|มาก|ที่สุด|ใน|โลก
          // วัน|นี้|อากาศ|ดี|มาก|ครับ: 15 words.
          final stats = WritingStats.of(
            'ผมชอบกินข้าวผัดมากที่สุดในโลก วันนี้อากาศดีมากครับ',
          );
          expect(stats.words, 13);
          expect(stats.sentences, 2);
          expect(stats.readingTime, const Duration(seconds: 4));
        });

        test('estimates Khmer words', () {
          // ICU: ខ្ញុំ|ចូលចិត្ត|ញ៉ាំបាយ|ណាស់។ ថ្ងៃនេះ|អាកាសធាតុ|ល្អ។: 7 words.
          final stats = WritingStats.of(
            'ខ្ញុំចូលចិត្តញ៉ាំបាយណាស់។ ថ្ងៃនេះអាកាសធាតុល្អ។',
          );
          expect(stats.words, 6);
          expect(stats.sentences, 2);
        });

        test('estimates Lao and Burmese words', () {
          // ICU: 13 words.
          final lao = WritingStats.of(
            'ປະເທດລາວມີພົນລະເມືອງປະມານເຈັດລ້ານຄົນ. '
            'ນະຄອນຫຼວງວຽງຈັນແມ່ນນະຄອນຫຼວງຂອງປະເທດ.',
          );
          expect(lao.words, 18);
          expect(lao.sentences, 2);
          // ICU: 15 words.
          final burmese = WritingStats.of(
            'မြန်မာနိုင်ငံသည် အရှေ့တောင်အာရှတွင် တည်ရှိသည်။ '
            'ရန်ကုန်မြို့သည် အကြီးဆုံးမြို့ ဖြစ်သည်။',
          );
          expect(burmese.words, 15);
          expect(burmese.sentences, 2);
        });

        test('counts every run as at least one word', () {
          // Words separated by zero-width spaces.
          expect(WritingStats.of('ខ្ញុំ​ចូលចិត្ត').words, 2);
          expect(WritingStats.of('iPhone รุ่นใหม่ ๒๕๖๗').words, 4);
        });

        test('uses the estimate for the reading time', () {
          final stats = WritingStats.of('ผมชอบกินข้าวผัดมากที่สุดในโลก ' * 20);
          expect(stats.words, 160);
          // 160 words at 238 a minute: 40.3 seconds.
          expect(stats.readingTime, const Duration(seconds: 41));
        });

        test('counts Tibetan by syllable', () {
          final stats = WritingStats.of('བཀྲ་ཤིས་བདེ་ལེགས།');
          expect(stats.words, 4);
          expect(stats.sentences, 1);
        });
      });

      test('counts letters with combining marks as one word', () {
        expect(WritingStats.of('Café नमस्ते').words, 2);
      });

      test('counts each Chinese character and kana as a word', () {
        final stats = WritingStats.of('今日は良い天気です。散歩しましょう！');
        expect(stats.words, 16);
        expect(stats.sentences, 2);
      });

      test('counts Korean by spaces', () {
        expect(WritingStats.of('안녕하세요 반갑습니다').words, 2);
      });

      test('mixes scripts', () {
        expect(WritingStats.of('Tokyo 東京 tower').words, 4);
      });
    });

    group('characters', () {
      test('counts grapheme clusters', () {
        expect(WritingStats.of('👍🏽 ok').characters, 4);
        expect(WritingStats.of('🇨🇭\n').characters, 2);
      });
    });

    group('sentences', () {
      int sentences(String text) => WritingStats.of(text).sentences;

      test('end with western terminators followed by a space or the end', () {
        expect(sentences('Wait... What?! Really? Yes!'), 4);
        expect(sentences('Pi is 3.14 today.'), 1);
        expect(sentences('Is it ‽ Yes'), 2);
      });

      test('include closing quotes and brackets', () {
        expect(sentences('He said "Stop." Then he left.'), 2);
        expect(sentences('(It works.) Good.'), 2);
      });

      test('skip initials and common abbreviations', () {
        expect(sentences('Mr. Smith met Dr. Jones. They talked.'), 2);
        expect(sentences('J. K. Rowling wrote it. Fans loved it!'), 2);
        expect(sentences('Written by J. K. Rowling. Fans loved it.'), 2);
        expect(sentences('John F. Kennedy was president. He died.'), 2);
        expect(sentences('Ask J. Smith. He knows.'), 2);
        expect(sentences('А. С. Пушкин родился в Москве. Он умер.'), 2);
        expect(sentences('Use e.g. this one. Done'), 2);
        expect(sentences('Big cities, e.g. Paris and Rome, are busy.'), 1);
        expect(sentences('We met at 10 a.m. on Monday.'), 1);
        expect(sentences('See p. 5 for details.'), 1);
        expect(sentences('The U.S. Army is large.'), 1);
        expect(sentences('Cats vs. dogs.'), 1);
      });

      test('a single letter can end a sentence', () {
        expect(sentences('The winner was I. Nobody else came.'), 2);
        expect(sentences('I moved to the U.S. Then I got a job.'), 2);
        expect(sentences('Take vitamin C. It helps.'), 2);
        expect(sentences('We need plan B. Then we go.'), 2);
        expect(sentences('Choose option a. Then continue.'), 2);
        expect(sentences('We left at 5 p.m. Then it rained.'), 2);
      });

      test('a syllable of an uncased script is never an initial', () {
        expect(sentences('네. 알겠습니다. 응. 좋아요.'), 4);
      });

      test('a terminator without a word is not a sentence', () {
        expect(sentences('Hello. ... !'), 1);
        expect(sentences('?!'), 0);
      });

      test('the end of a line ends a sentence', () {
        expect(
          WritingStats.of(
            '# Title\nFirst line. Second line.\n\n- item one\n- item two',
          ).sentences,
          5,
        );
      });

      test('in other scripts', () {
        expect(sentences('مرحبا بك. كيف حالك؟ جيد'), 3);
        expect(sentences('नमस्ते। आप कैसे हैं?'), 2);
        expect(sentences('你好。你好吗？我很好！'), 3);
        expect(sentences('Ես սիրում եմ գրքեր։ Այսօր եղանակը լավ է։'), 2);
        expect(sentences('እኔ መጽሐፍ እወዳለሁ። ዛሬ አየሩ ጥሩ ነው። ደህና ነህ፧'), 3);
        expect(sentences('ខ្ញុំសុខសប្បាយ។ អរគុណ៕'), 2);
        expect(sentences('ကျေးဇူးတင်ပါတယ်။ နေကောင်းလား။'), 2);
        expect(
          sentences('བཀྲ་ཤིས་བདེ་ལེགས། ཁྱེད་རང་སྐུ་གཟུགས་བདེ་པོ་ཡིན་པས།'),
          2,
        );
        // Head marks and a double shad open a Tibetan text.
        expect(sentences('༄༅། །བཀྲ་ཤིས་བདེ་ལེགས༎'), 1);
      });

      test('a space between Thai words ends a sentence', () {
        expect(sentences('ผมชอบกินข้าวผัด วันนี้อากาศดีมาก ขอบคุณครับ'), 3);
        // Not around numbers, the repetition mark ๆ or after ฯ.
        expect(sentences('ราคา 100 บาท'), 1);
        expect(sentences('เด็ก ๆ เล่นกัน'), 1);
        expect(sentences('กรุงเทพฯ เป็นเมืองหลวง'), 1);
      });
    });

    group('paragraphs', () {
      test('count lines with words', () {
        expect(WritingStats.of('One.\nTwo.\r\nThree.\rFour.').paragraphs, 4);
        expect(WritingStats.of('One.\n\n   \n---\nTwo.').paragraphs, 2);
        expect(WritingStats.of('A B C').paragraphs, 3);
      });
    });

    group('reading time', () {
      test('uses words per minute, rounded up to a second', () {
        expect(
          WritingStats.of('word ' * WritingStats.wordsPerMinute).readingTime,
          const Duration(minutes: 1),
        );
        expect(
          WritingStats.of('word ' * (WritingStats.wordsPerMinute + 1))
              .readingTime,
          const Duration(seconds: 61),
        );
        expect(WritingStats.of('Hi.').readingTime, const Duration(seconds: 1));
      });

      test('uses characters per minute for Chinese and Japanese', () {
        expect(
          WritingStats.of('字' * WritingStats.cjkCharactersPerMinute)
              .readingTime,
          const Duration(minutes: 1),
        );
      });
    });

    group('Flesch reading ease', () {
      test('is computed for English', () {
        // 14 words, 2 sentences, 17 syllables:
        // 206.835 - 1.015 * 7 - 84.6 * 17 / 14 = 97.0014...
        final stats = WritingStats.of(
          'The quick brown fox jumps over the lazy dog. It was a sunny day.',
          languageCode: 'en',
        );
        expect(stats.fleschReadingEase, closeTo(97.0014, 0.0001));
        expect(stats.fleschBand, FleschBand.veryEasy);
      });

      test('accepts regional English codes', () {
        for (final code in ['en-GB', 'EN_us', ' en ']) {
          expect(
            WritingStats.of(
              'It is fine.',
              languageCode: code,
            ).fleschReadingEase,
            isNotNull,
            reason: code,
          );
        }
      });

      test('is clamped to 0–100', () {
        expect(
          WritingStats.of('The cat sat.', languageCode: 'en').fleschReadingEase,
          100,
        );
        expect(
          WritingStats.of(
            'Comprehensive documentation facilitates organizational '
            'understanding.',
            languageCode: 'en',
          ).fleschReadingEase,
          0,
        );
      });

      test('is hidden for other or unknown languages', () {
        const text = 'Der Hund schläft. Die Katze spielt.';
        expect(
          WritingStats.of(text, languageCode: 'de').fleschReadingEase,
          isNull,
        );
        expect(WritingStats.of(text).fleschReadingEase, isNull);
        expect(
          WritingStats.of(text, languageCode: 'eng').fleschReadingEase,
          isNull,
        );
      });

      test('needs words', () {
        expect(
          WritingStats.of('今日は。', languageCode: 'en').fleschReadingEase,
          isNull,
        );
      });
    });

    test('supports value equality', () {
      expect(WritingStats.of('A b.'), WritingStats.of('A b.'));
      expect(WritingStats.of('A b.'), isNot(WritingStats.of('A b c.')));
    });
  });

  group('WritingStats.fleschScore', () {
    test('applies the formula', () {
      // 206.835 - 1.015 * 20 - 84.6 * 1.5
      expect(
        WritingStats.fleschScore(words: 100, sentences: 5, syllables: 150),
        closeTo(59.635, 0.0001),
      );
    });

    test('is 0 without words or sentences', () {
      expect(WritingStats.fleschScore(words: 0, sentences: 1, syllables: 0), 0);
      expect(WritingStats.fleschScore(words: 3, sentences: 0, syllables: 3), 0);
    });
  });

  group('WritingStats.englishSyllables', () {
    const expected = {
      'the': 1,
      'cat': 1,
      'make': 1,
      'makes': 1,
      'boxes': 2,
      'horses': 2,
      'jumped': 1,
      'played': 1,
      'wanted': 2,
      'needed': 2,
      'table': 2,
      'people': 2,
      'yellow': 2,
      'over': 2,
      'lazy': 2,
      'estimate': 3,
      'difficulty': 4,
      'readability': 5,
      'organizational': 6,
      'Quick,': 1,
      '2024': 1,
      'été': 1,
      'rhythm': 1,
    };
    expected.forEach((word, syllables) {
      test(word, () {
        expect(WritingStats.englishSyllables(word), syllables);
      });
    });
  });

  group('WritingStats.isEnglish', () {
    test('matches English codes only', () {
      expect(WritingStats.isEnglish('en'), isTrue);
      expect(WritingStats.isEnglish('en-AU'), isTrue);
      expect(WritingStats.isEnglish('en_gb'), isTrue);
      expect(WritingStats.isEnglish('de'), isFalse);
      expect(WritingStats.isEnglish(''), isFalse);
      expect(WritingStats.isEnglish(null), isFalse);
    });
  });

  group('FleschBand.of', () {
    test('uses Flesch’s bands', () {
      const bands = [
        (100.0, FleschBand.veryEasy),
        (90.0, FleschBand.veryEasy),
        (89.9, FleschBand.easy),
        (80.0, FleschBand.easy),
        (75.0, FleschBand.fairlyEasy),
        (65.0, FleschBand.standard),
        (55.0, FleschBand.fairlyDifficult),
        (40.0, FleschBand.difficult),
        (30.0, FleschBand.difficult),
        (29.9, FleschBand.veryDifficult),
        (0.0, FleschBand.veryDifficult),
      ];
      for (final (score, band) in bands) {
        expect(FleschBand.of(score), band, reason: '$score');
      }
    });
  });
}
