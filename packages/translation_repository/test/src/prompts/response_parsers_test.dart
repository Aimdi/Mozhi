import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('ResponseParsers.extractJsonObject', () {
    Map<String, dynamic> extract(String text) =>
        ResponseParsers.extractJsonObject(text);

    test('plain object', () {
      expect(extract('{"a": 1, "b": [true, null]}'), {
        'a': 1,
        'b': [true, null],
      });
    });

    test('json code fence', () {
      expect(extract('```json\n{"a": "x"}\n```'), {'a': 'x'});
      expect(extract('```\n{"a": "x"}\n```'), {'a': 'x'});
      expect(extract('```JSON {"a": "x"}```'), {'a': 'x'});
    });

    test('prose before and after', () {
      expect(
        extract(
          'Sure! Here is the JSON you asked for:\n\n'
          '```json\n{"alternatives": [{"text": "Salut"}]}\n```\n\n'
          'Let me know if you need anything else.',
        ),
        {
          'alternatives': [
            {'text': 'Salut'},
          ],
        },
      );
      expect(extract('Result: {"a": 1} -- hope that helps {smile}'), {'a': 1});
    });

    test('skips brace pairs in prose that are not JSON', () {
      expect(extract('Use the {placeholder} syntax. {"ok": true}'), {
        'ok': true,
      });
    });

    test('think blocks', () {
      expect(
        extract(
          '<think>\nThe user wants {"wrong": 1}. Let me think...\n</think>\n'
          '{"right": 2}',
        ),
        {'right': 2},
      );
      expect(extract('<thinking>{"wrong": 1}</thinking>{"right": 2}'), {
        'right': 2,
      });
      // Opening tag swallowed by the server.
      expect(extract('reasoning {"wrong": 1}</think>\n{"right": 2}'), {
        'right': 2,
      });
      // Unterminated block that contains the only JSON.
      expect(extract('<think>{"only": 3}'), {'only': 3});
    });

    test('trailing commas', () {
      expect(extract('{"a": [1, 2, 3,], "b": {"c": "d",},}'), {
        'a': [1, 2, 3],
        'b': {'c': 'd'},
      });
      expect(extract('{"a": [1, 2,\n  ],\n}'), {
        'a': [1, 2],
      });
    });

    test('braces, brackets and quotes inside strings', () {
      expect(extract(r'{"text": "a } b { c ] [ \"quoted\" \\ end", "n": 1}'), {
        'text': r'a } b { c ] [ "quoted" \ end',
        'n': 1,
      });
      expect(
        extract('noise {"code": "if (x) { y(); }", "list": "[1,]"} tail'),
        {'code': 'if (x) { y(); }', 'list': '[1,]'},
      );
    });

    test('smart quotes around keys and values', () {
      expect(extract('{“text”: “Bonjour”, “n”: 2}'), {
        'text': 'Bonjour',
        'n': 2,
      });
      // Smart quotes inside a normal string are content.
      expect(extract('{"text": "Er sagte „Hallo“"}'), {
        'text': 'Er sagte „Hallo“',
      });
    });

    test('raw newlines and tabs inside strings', () {
      expect(extract('{"corrected": "line 1\nline 2\tx"}'), {
        'corrected': 'line 1\nline 2\tx',
      });
      expect(extract('{"a": "x\r\ny"}'), {'a': 'x\r\ny'});
    });

    test('escaped quotes while scanning, repairing and closing', () {
      expect(extract(r'Here: {"a": "say \"hi\" {"}'), {'a': 'say "hi" {'});
      expect(extract(r'{"a": "say \"hi\"", "b": [1,],}'), {
        'a': 'say "hi"',
        'b': [1],
      });
      expect(extract(r'{"a": "say \"hi\"", "b": "unfinish'), {
        'a': 'say "hi"',
        'b': 'unfinish',
      });
    });

    test('invalid escapes', () {
      expect(extract(r'''{"text": "it\'s"}'''), {'text': "it's"});
    });

    test('python literals', () {
      expect(extract("{'a': True}".replaceAll("'", '"')), {'a': true});
      expect(extract('{"a": True, "b": False, "c": None, "d": "True"}'), {
        'a': true,
        'b': false,
        'c': null,
        'd': 'True',
      });
    });

    test('returns the first object of a top-level array', () {
      expect(extract('[{"a": 1}, {"a": 2}]'), {'a': 1});
      expect(extract('Here: [1, {"a": 1}]'), {'a': 1});
    });

    test('repairs output truncated by a token limit', () {
      expect(extract('{"insights": [{"target": "a"}, {"target": "b", "expl'), {
        'insights': [
          {'target': 'a'},
          {'target': 'b'},
        ],
      });
      expect(extract('{"description": "Une traduction'), {
        'description': 'Une traduction',
      });
      expect(extract('```json\n{"a": 1, "b": [1, 2'), {
        'a': 1,
        'b': [1, 2],
      });
    });

    test('non-string keys are stringified', () {
      // Only reachable through lists of maps; keys in JSON are strings, so
      // this is just the identity.
      expect(extract('{"1": 2}'), {'1': 2});
    });

    test('throws FormatException when nothing is parseable', () {
      for (final text in [
        '',
        '   ',
        'I cannot help with that.',
        '[1, 2, 3]',
        '{not json at all}',
        '<think>{"a": ',
        '}{',
      ]) {
        expect(() => extract(text), throwsFormatException, reason: text);
      }
    });
  });

  group('ResponseParsers.splitLanguageMarker', () {
    final cases = <String, (String?, String)>{
      '[[lang:fr]]\nBonjour': ('fr', 'Bonjour'),
      '[[lang:fr]]Bonjour': ('fr', 'Bonjour'),
      '[[lang:fr]] Bonjour': ('fr', 'Bonjour'),
      '  [[lang:fr]]  \r\nBonjour': ('fr', 'Bonjour'),
      '[[lang:fr]]\n\nBonjour\n\nÇa va ?': ('fr', 'Bonjour\n\nÇa va ?'),
      '[[lang:fr]]\n  indented': ('fr', '  indented'),
      '[[LANG: FR]]\nBonjour': ('fr', 'Bonjour'),
      '[[language=de]]\nHallo': ('de', 'Hallo'),
      '[[lang:zh-tw]]\n你好': ('zh-TW', '你好'),
      '[[lang:zh_Hant]]\n你好': ('zh-TW', '你好'),
      '[[lang:iw]]\nשלום': ('he', 'שלום'),
      '[[lang:sr-Latn]]\nZdravo': ('sr-Latn', 'Zdravo'),
      '[lang:es]\nHola': ('es', 'Hola'),
      '[ lang : es ]\nHola': ('es', 'Hola'),
      '⟦ja⟧\nこんにちは': ('ja', 'こんにちは'),
      '⟦lang:ja⟧こんにちは': ('ja', 'こんにちは'),
      '[[en]]\nHello': ('en', 'Hello'),
      '[[lang:fr]]': ('fr', ''),
      '[[lang:fr]]\n': ('fr', ''),
      // Marker on the last line instead.
      'Bonjour\n[[lang:fr]]': ('fr', 'Bonjour'),
      'Bonjour [[lang:fr]]  \n': ('fr', 'Bonjour'),
      // Not markers.
      'Bonjour': (null, 'Bonjour'),
      '': (null, ''),
      '[[Paris]] is a city': (null, '[[Paris]] is a city'),
      '[sic] text': (null, '[sic] text'),
      '[fr]\nBonjour': (null, '[fr]\nBonjour'),
      '[Music playing]': (null, '[Music playing]'),
      'Text with [[lang:fr]] inside it.': (
        null,
        'Text with [[lang:fr]] inside it.',
      ),
      '[[lang:]]\nx': (null, '[[lang:]]\nx'),
      '[[lang:toolong]]\nx': (null, '[[lang:toolong]]\nx'),
    };

    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test(input.replaceAll('\n', r'\n').replaceAll('\r', r'\r'), () {
        final result = ResponseParsers.splitLanguageMarker(input);
        expect(result.language, expected.$1);
        expect(result.text, expected.$2);
      });
    }
  });

  group('ResponseParsers.isMarkerPending', () {
    const pending = [
      '',
      '  ',
      '[',
      '[[',
      '[[l',
      '[[la',
      '[[lang',
      '[[lang:',
      '[[lang: ',
      '[[lang:f',
      '[[lang:fr',
      '[[lang:fr]',
      '[[lang:zh-',
      '[[lang:zh-T',
      '[[langu',
      '[[language:',
      '[[fr',
      '[[ ',
      '[l',
      '[lan',
      '[lang:',
      '[lang:es',
      '⟦',
      '⟦j',
      '⟦lang:',
      '  [[lang',
      '[[LANG:FR',
      // Could still become a code-only marker such as [[pt]] or [[pa]].
      '[[P',
      '[[Pa',
      '[[Par',
    ];
    const notPending = [
      '[[lang:fr]]',
      '[[lang:fr]]\nBon',
      '[lang:es]',
      '⟦ja⟧',
      'B',
      'Bonjour',
      '[N',
      '[Note: this',
      '[lat',
      '[laughs]',
      '[[Pari',
      '[[Paris',
      '[[lang:abcd',
      '[[lang:fr]x',
      '[[x\n',
      '"[[lang',
      '[[lang:zh-Hant-TW-very-long-tag-here-and-more',
    ];
    for (final text in pending) {
      test('pending: "$text"', () {
        expect(ResponseParsers.isMarkerPending(text), isTrue);
      });
    }
    for (final text in notPending) {
      test('not pending: "${text.replaceAll('\n', r'\n')}"', () {
        expect(ResponseParsers.isMarkerPending(text), isFalse);
      });
    }

    test('streaming simulation never shows the marker', () {
      const full = '[[lang:de]]\nGuten Morgen!';
      String? shownLanguage;
      final shown = <String>[];
      for (var i = 1; i <= full.length; i++) {
        final accumulated = full.substring(0, i);
        if (ResponseParsers.isMarkerPending(accumulated)) continue;
        final split = ResponseParsers.splitLanguageMarker(accumulated);
        shownLanguage = split.language;
        shown.add(split.text);
      }
      expect(shownLanguage, 'de');
      expect(shown.where((s) => s.contains('[')), isEmpty);
      expect(shown.last, 'Guten Morgen!');
    });
  });

  group('ResponseParsers.cleanTranslation', () {
    String clean(String output, [String source = 'Hello there']) =>
        ResponseParsers.cleanTranslation(output, source: source);

    test('trims surrounding whitespace', () {
      expect(clean('  Bonjour  \n'), 'Bonjour');
      expect(clean('\n\nBonjour'), 'Bonjour');
    });

    test('keeps leading indentation when the source has it', () {
      expect(clean('\n    code()\n', '    code()'), '    code()');
    });

    test('strips wrapping quotes the source did not have', () {
      expect(clean('"Bonjour"'), 'Bonjour');
      expect(clean('“Bonjour”'), 'Bonjour');
      expect(clean('«Bonjour»'), 'Bonjour');
      expect(clean('„Hallo“'), 'Hallo');
      expect(clean('「こんにちは」'), 'こんにちは');
      expect(clean("'Hola'"), 'Hola');
      expect(clean('"He said “hi”"'), 'He said “hi”');
    });

    test('keeps quotes that belong to the text', () {
      expect(clean('"Bonjour"', '"Hello"'), '"Bonjour"');
      expect(clean('«Bonjour»', '„Hallo“'), '«Bonjour»');
      expect(clean('"Oui", dit-il, "non"'), '"Oui", dit-il, "non"');
      expect(clean('"'), '"');
      expect(clean('""'), '""');
      expect(clean('Il a dit "oui"'), 'Il a dit "oui"');
    });

    test('strips wrapper tags', () {
      expect(clean('<translation>Bonjour</translation>'), 'Bonjour');
      expect(clean('<translation>\nBonjour\n</translation>'), 'Bonjour');
      expect(clean('<source>\nBonjour\n</source>'), 'Bonjour');
      expect(clean('<target lang="fr">Bonjour</target>'), 'Bonjour');
      expect(clean('<output>\nBonjour'), 'Bonjour');
      expect(
        clean(
          '<source>\nHello there\n</source>\n'
          '<translation>\nBonjour\n</translation>',
        ),
        'Bonjour',
      );
    });

    test('keeps tags present in the source', () {
      expect(
        clean('<source>Bonjour</source>', '<source>Hello</source>'),
        '<source>Bonjour</source>',
      );
      expect(
        clean(
          '<translation>Bonjour</translation>',
          '<translation>Hello</translation>',
        ),
        '<translation>Bonjour</translation>',
      );
    });

    test('strips "Translation:" style labels', () {
      expect(clean('Translation: Bonjour'), 'Bonjour');
      expect(clean('translation:\nBonjour'), 'Bonjour');
      expect(clean('**Translation:** Bonjour'), 'Bonjour');
      expect(clean('Translation (French): Bonjour'), 'Bonjour');
      expect(clean('Translation into French:\n\nBonjour'), 'Bonjour');
      expect(clean("Here's the translation:\n\nBonjour"), 'Bonjour');
      expect(
        clean('Sure! Here is the translation into French:\n"Bonjour"'),
        'Bonjour',
      );
      expect(clean('Translated text: Bonjour'), 'Bonjour');
    });

    test('keeps labels present in the source or with nothing after', () {
      expect(
        clean('Traduction : Bonjour', 'Translation: Hello'),
        'Traduction : Bonjour',
      );
      expect(
        clean('Translation: Bonjour', 'Translation: Hello'),
        'Translation: Bonjour',
      );
      expect(clean('Translation:'), 'Translation:');
      // The source starts with a label of its own.
      expect(
        clean('Translation: the act of translating', 'Traducción: el acto'),
        'Translation: the act of translating',
      );
      expect(clean('Translations are hard'), 'Translations are hard');
    });

    test('unwraps a code fence around everything', () {
      expect(clean('```\nBonjour\n```'), 'Bonjour');
      expect(clean('```text\nBonjour\n```'), 'Bonjour');
      expect(
        clean('```dart\nprint(1);\n```', '```dart\nprint(1);\n```'),
        '```dart\nprint(1);\n```',
      );
      expect(clean('```\n```'), '```\n```');
    });

    test('drops a trailing note paragraph', () {
      expect(
        clean('Bonjour tout le monde.\n\nNote: "Hello there" is informal.'),
        'Bonjour tout le monde.',
      );
      expect(clean('Bonjour.\n\n(Note: kept the tone.)'), 'Bonjour.');
      expect(
        clean("Bonjour.\n\n*Translator's note:* idiom adapted."),
        'Bonjour.',
      );
    });

    test('keeps notes the source asked for', () {
      expect(
        clean('Bonjour.\n\nNote : à demain.', 'Hello.\n\nNote: see you.'),
        'Bonjour.\n\nNote : à demain.',
      );
      expect(clean('Note: bonjour'), 'Note: bonjour');
      // The source has a matching final paragraph.
      expect(
        clean('Bonjour.\n\nNote: demain.', 'Hallo.\n\nHinweis: morgen.'),
        'Bonjour.\n\nNote: demain.',
      );
    });

    test('combines several cleanups', () {
      expect(
        clean('Translation:\n<translation>\n"Bonjour"\n</translation>'),
        'Bonjour',
      );
    });

    test('leaves normal text untouched', () {
      const text = 'Bonjour !\n\n- un\n- deux\n\n**gras** et `code`';
      expect(
        clean(text, 'Hello!\n\n- one\n- two\n\n**bold** and `code`'),
        text,
      );
    });
  });

  group('ResponseParsers.parseAlternatives', () {
    test('parses the documented schema', () {
      final result = ResponseParsers.parseAlternatives('''
{"description": "A neutral, polite rendering.",
 "alternatives": [
   {"text": "Salut", "explanation": "more casual"},
   {"text": "Bonjour à tous", "explanation": "addresses everyone"}
 ]}''');
      expect(result.description, 'A neutral, polite rendering.');
      expect(result.alternatives, const [
        Alternative(text: 'Salut', explanation: 'more casual'),
        Alternative(text: 'Bonjour à tous', explanation: 'addresses everyone'),
      ]);
    });

    test("accepts Kagi's field names, strings and drops junk", () {
      final result = ResponseParsers.parseAlternatives('''
```json
{"original_description": "Neutral.",
 "elements": [
   {"translation": "Salut", "description": "casual"},
   "Coucou",
   {"translation": "  "},
   {"translation": "Salut", "description": "duplicate"},
   42
 ]}
```''');
      expect(result.description, 'Neutral.');
      expect(result.alternatives, const [
        Alternative(text: 'Salut', explanation: 'casual'),
        Alternative(text: 'Coucou'),
      ]);
    });

    test('a bare array and an unknown list key', () {
      expect(
        ResponseParsers.parseAlternatives('[{"text": "A"}, {"text": "B"}]')
            .alternatives
            .map((a) => a.text),
        ['A', 'B'],
      );
      final other = ResponseParsers.parseAlternatives(
        '{"description": "d", "variants": [{"text": "A"}]}',
      );
      expect(other.alternatives.single.text, 'A');
      expect(other.description, 'd');
    });

    test('missing fields give empty results', () {
      final result = ResponseParsers.parseAlternatives('{"foo": 1}');
      expect(result.description, isEmpty);
      expect(result.alternatives, isEmpty);
    });

    test('throws on non-JSON', () {
      expect(
        () => ResponseParsers.parseAlternatives('No alternatives.'),
        throwsFormatException,
      );
    });
  });

  group('ResponseParsers.parseInsights', () {
    const translation = 'Il pleut des cordes, mais « c’est la vie ».';

    test('parses and keeps only targets found in the translation', () {
      final insights = ResponseParsers.parseInsights('''
<think>Find idioms.</think>
{"insights": [
  {"source": "raining cats and dogs", "target": "Il pleut des cordes",
   "type": "Idiom", "explanation": "French idiom for heavy rain.",
   "variations": [
     {"text": "Il pleut à verse", "explanation": "more neutral"},
     "Il tombe des cordes",
     {"text": "Il pleut des cordes"},
     {"text": ""}
   ]},
  {"source": "x", "target": "not in the translation", "type": "nuance"},
  {"source": "y", "target": "", "type": "nuance"},
  "junk",
  {"source": "that's life", "target": "c’est la vie", "type": "cultural"},
  {"source": "dup", "target": "c’est la vie"},
]}''', translation: translation);
      expect(insights, hasLength(2));
      expect(
        insights.first,
        const WordInsight(
          sourceText: 'raining cats and dogs',
          targetText: 'Il pleut des cordes',
          type: 'idiom',
          explanation: 'French idiom for heavy rain.',
          variations: [
            Alternative(text: 'Il pleut à verse', explanation: 'more neutral'),
            Alternative(text: 'Il tombe des cordes'),
          ],
        ),
      );
      expect(insights.last.targetText, 'c’est la vie');
      expect(insights.last.type, 'cultural');
    });

    test('repairs targets with extra quotes or different case', () {
      final insights = ResponseParsers.parseInsights(
        '{"insights": [ '
        r'{"source": "a", "target": "\"mais\""}, '
        '{"source": "b", "target": "IL PLEUT"}, '
        '{"source": "c", "target": "“c’est la vie”", "type": ""} '
        ']}',
        translation: translation,
      );
      expect(insights.map((i) => i.targetText), [
        'mais',
        'Il pleut',
        'c’est la vie',
      ]);
      expect(insights.last.type, 'nuance');
    });

    test('a bare array with alternative key names', () {
      final insights = ResponseParsers.parseInsights(
        '[{"original_text": "rain", "target_text": "pleut", '
        '"category": "grammar", "description": "verb", '
        '"alternatives": ["tombe"]}]',
        translation: translation,
      );
      expect(insights.single.sourceText, 'rain');
      expect(insights.single.targetText, 'pleut');
      expect(insights.single.type, 'grammar');
      expect(insights.single.explanation, 'verb');
      expect(insights.single.variations.single.text, 'tombe');
    });

    test('empty when the model found nothing', () {
      expect(
        ResponseParsers.parseInsights(
          '{"insights": []}',
          translation: translation,
        ),
        isEmpty,
      );
    });
  });

  group('ResponseParsers.parseSuggestions', () {
    test('parses the documented schema', () {
      final suggestions = ResponseParsers.parseSuggestions('''
{"suggestions": [
  {"label": "More formal", "description": "Use vous.",
   "instruction": "Address the reader with vous.", "icon": "formal"},
  {"label": "Shorter", "description": "Trim it.", "instruction": "",
   "icon": "concise"},
  {"label": "Regional", "instruction": "Use Québécois vocabulary.",
   "icon": "map"},
  {"label": "more formal", "instruction": "duplicate"},
  {"label": "", "instruction": "no label"},
  {"label": "Plain", "icon": "Simpler"}
]}''');
      expect(suggestions, const [
        RefinementSuggestion(
          label: 'More formal',
          instruction: 'Address the reader with vous.',
          description: 'Use vous.',
          icon: 'formal',
        ),
        RefinementSuggestion(
          label: 'Shorter',
          instruction: 'Trim it.',
          description: 'Trim it.',
          icon: 'shorter',
        ),
        RefinementSuggestion(
          label: 'Regional',
          instruction: 'Use Québécois vocabulary.',
        ),
        RefinementSuggestion(
          label: 'Plain',
          instruction: 'Plain',
          icon: 'simplify',
        ),
      ]);
    });

    test('maps icon synonyms', () {
      const icons = {
        'tune': 'tune',
        'FORMAL': 'formal',
        'polite': 'formal',
        'informal': 'casual',
        'expand': 'longer',
        'natural': 'fluent',
        'faithful': 'literal',
        'rocket': 'tune',
        '': 'tune',
      };
      icons.forEach((raw, icon) {
        final parsed = ResponseParsers.parseSuggestions(
          '{"suggestions": [{"label": "L", "instruction": "I", '
          '"icon": "$raw"}]}',
        );
        expect(parsed.single.icon, icon, reason: raw);
      });
    });

    test('a bare array and title/prompt keys', () {
      final parsed = ResponseParsers.parseSuggestions(
        '[{"title": "Casual", "prompt": "Make it casual.", "category": '
        '"casual"}]',
      );
      expect(parsed.single.label, 'Casual');
      expect(parsed.single.instruction, 'Make it casual.');
      expect(parsed.single.icon, 'casual');
    });
  });

  group('ResponseParsers.parseDictionary', () {
    test('parses the documented schema', () {
      final entry = ResponseParsers.parseDictionary('''
```json
{
  "word": "bank",
  "pronunciation": "/bæŋk/",
  "parts_of_speech": ["noun", "verb"],
  "senses": [
    {"part_of_speech": "noun", "definition": "A financial institution.",
     "translations": ["Bank", "Geldinstitut"], "usage": ""},
    {"part_of_speech": "noun", "definition": "The side of a river.",
     "translations": "Ufer, Böschung", "usage": "geography"},
    {"definition": ""},
    "to tilt an aircraft"
  ],
  "examples": [
    {"source": "I went to the bank.", "translation": "Ich ging zur Bank."},
    "We sat on the bank.",
    {"source": ""}
  ],
  "synonyms": ["lender", "shore", "", 7],
  "etymology": "From Italian banca.",
  "notes": "False friend: German Bank also means bench.",
}
```''');
      expect(entry.word, 'bank');
      expect(entry.pronunciation, '/bæŋk/');
      expect(entry.partsOfSpeech, ['noun', 'verb']);
      expect(entry.senses, const [
        DictionarySense(
          definition: 'A financial institution.',
          partOfSpeech: 'noun',
          translations: ['Bank', 'Geldinstitut'],
        ),
        DictionarySense(
          definition: 'The side of a river.',
          partOfSpeech: 'noun',
          translations: ['Ufer', 'Böschung'],
          usage: 'geography',
        ),
        DictionarySense(definition: 'to tilt an aircraft'),
      ]);
      expect(entry.examples, const [
        DictionaryExample(
          source: 'I went to the bank.',
          translation: 'Ich ging zur Bank.',
        ),
        DictionaryExample(source: 'We sat on the bank.'),
      ]);
      expect(entry.synonyms, ['lender', 'shore', '7']);
      expect(entry.etymology, 'From Italian banca.');
      expect(entry.notes, startsWith('False friend'));
    });

    test('camelCase keys, string lists and derived parts of speech', () {
      final entry = ResponseParsers.parseDictionary(
        '{"headword": "run", "ipa": "/rʌn/", '
        '"meanings": [{"partOfSpeech": "verb", "meaning": "move fast", '
        '"translation": "courir", "register": "common"}], '
        '"synonyms": "sprint; dash", "origin": "Old English"}',
      );
      expect(entry.word, 'run');
      expect(entry.pronunciation, '/rʌn/');
      expect(entry.partsOfSpeech, ['verb']);
      expect(entry.senses.single.translations, ['courir']);
      expect(entry.senses.single.usage, 'common');
      expect(entry.synonyms, ['sprint', 'dash']);
      expect(entry.etymology, 'Old English');
    });

    test("Kagi's primary_meaning shape", () {
      final entry = ResponseParsers.parseDictionary(
        '{"word": "Haus", "primary_meaning": {"part_of_speech": ["noun"], '
        '"usage_level": ["common"], "definition": "A building.", '
        '"synonyms": [{"word": "Gebäude"}]}, "synonyms": [{"word": "Heim"}]}',
      );
      expect(entry.senses.single.definition, 'A building.');
      expect(entry.senses.single.partOfSpeech, 'noun');
      expect(entry.senses.single.usage, 'common');
      expect(entry.partsOfSpeech, ['noun']);
      expect(entry.synonyms, ['Heim']);
    });

    test('a bare array and empty objects', () {
      expect(ResponseParsers.parseDictionary('[{"word": "x"}]').word, 'x');
      final empty = ResponseParsers.parseDictionary('{"unrelated": 1}');
      expect(empty.word, isEmpty);
      expect(empty.senses, isEmpty);
      expect(empty.partsOfSpeech, isEmpty);
    });
  });

  group('ResponseParsers.parseProofread', () {
    const input = 'Their is a error in this sentense. Their is more.';

    test('parses edits and drops ones not in the input', () {
      final result = ResponseParsers.parseProofread(r'''
{"language": "EN", "corrected": "There is an error in this sentence. There is more.",
 "summary": "Mostly fine.",
 "edits": [
   {"original": "Their is a error", "replacement": "There is an error",
    "explanation": "Wrong word and article.", "category": "Grammar"},
   {"original": "sentense", "replacement": "sentence",
    "explanation": "Typo.", "category": "typo"},
   {"original": "hallucinated text", "replacement": "x"},
   {"original": "", "replacement": "x"},
   {"original": "more", "replacement": "more"},
   {"original": "\"Their is more\"", "replacement": "There is more",
    "category": "word choice"},
   "junk"
 ]}''', input: input);
      expect(result.detectedLanguage, 'en');
      expect(
        result.correctedText,
        'There is an error in this sentence. There is more.',
      );
      expect(result.summary, 'Mostly fine.');
      expect(result.edits, const [
        ProofreadEdit(
          original: 'Their is a error',
          replacement: 'There is an error',
          explanation: 'Wrong word and article.',
        ),
        ProofreadEdit(
          original: 'sentense',
          replacement: 'sentence',
          explanation: 'Typo.',
          category: 'spelling',
        ),
        ProofreadEdit(
          original: 'Their is more',
          replacement: 'There is more',
          category: 'word_choice',
        ),
      ]);
    });

    test('applies the edits when "corrected" is missing', () {
      final result = ResponseParsers.parseProofread(
        '{"edits": [{"original": "sentense", "replacement": "sentence"}]}',
        input: input,
      );
      expect(
        result.correctedText,
        'Their is a error in this sentence. Their is more.',
      );
      expect(result.detectedLanguage, isNull);
    });

    test('a bare array of edits and alternative keys', () {
      final result = ResponseParsers.parseProofread(
        '[{"before": "a error", "after": "an error", "reason": "article", '
        '"type": "fluency"}]',
        input: input,
      );
      expect(result.edits.single.original, 'a error');
      expect(result.edits.single.replacement, 'an error');
      expect(result.edits.single.explanation, 'article');
      expect(result.edits.single.category, 'style');
      expect(result.correctedText, contains('an error'));
    });

    test('maps categories', () {
      const categories = {
        'spelling': 'spelling',
        'Word Choice': 'word_choice',
        'word-choice': 'word_choice',
        'vocabulary': 'word_choice',
        'redundancy': 'repetition',
        'register': 'tone',
        'conciseness': 'clarity',
        'syntax': 'grammar',
        'punctuation': 'punctuation',
        '': 'grammar',
        'weird': 'style',
      };
      categories.forEach((raw, category) {
        final result = ResponseParsers.parseProofread(
          '{"edits": [{"original": "sentense", "replacement": "sentence", '
          '"category": "$raw"}]}',
          input: input,
        );
        expect(result.edits.single.category, category, reason: raw);
      });
    });

    test('language names are mapped to codes', () {
      final result = ResponseParsers.parseProofread(
        '{"language": "German", "corrected": "x", "edits": []}',
        input: 'x',
      );
      expect(result.detectedLanguage, 'de');
    });

    test('unchanged text', () {
      final result = ResponseParsers.parseProofread(
        '{"language": "en", "corrected": "Fine.", "summary": "", '
        '"edits": []}',
        input: 'Fine.',
      );
      expect(result.correctedText, 'Fine.');
      expect(result.edits, isEmpty);
    });
  });

  group('ResponseParsers.parseDetectedLanguage', () {
    test('parses the documented schema', () {
      final result = ResponseParsers.parseDetectedLanguage(
        '{"language": "pt-br", "uncertain": true, "mixed": false, '
        '"alternatives": ["pt-PT", "es", "pt-br", "", "gl"]}',
      );
      expect(
        result,
        const DetectedLanguage(
          code: 'pt-BR',
          isUncertain: true,
          alternatives: ['pt-PT', 'es', 'gl'],
        ),
      );
    });

    test("Kagi's shape and string booleans", () {
      final result = ResponseParsers.parseDetectedLanguage(
        '{"iso": "iw", "isUncertain": "false", "isMixed": "yes", '
        '"alternatives": [{"iso": "yi"}, {"label": "x"}]}',
      );
      expect(result.code, 'he');
      expect(result.isUncertain, isFalse);
      expect(result.isMixed, isTrue);
      expect(result.alternatives, ['yi']);
    });

    test('language names and numeric booleans', () {
      final result = ResponseParsers.parseDetectedLanguage(
        '```json\n{"language": "Japanese", "uncertain": 1}\n```',
      );
      expect(result.code, 'ja');
      expect(result.isUncertain, isTrue);
      expect(
        ResponseParsers.parseDetectedLanguage(
          '{"language": "Chinese (Traditional)"}',
        ).code,
        'zh-TW',
      );
      expect(
        ResponseParsers.parseDetectedLanguage('{"language": "Ewe"}').code,
        'ee',
      );
    });

    test('unknown but well-formed codes are kept', () {
      expect(
        ResponseParsers.parseDetectedLanguage('{"language": "xyz"}').code,
        'xyz',
      );
    });

    test('plain-text answers', () {
      expect(ResponseParsers.parseDetectedLanguage('fr').code, 'fr');
      expect(ResponseParsers.parseDetectedLanguage(' FR\n').code, 'fr');
      expect(ResponseParsers.parseDetectedLanguage('[[lang:de]]').code, 'de');
      expect(
        ResponseParsers.parseDetectedLanguage('<think>hm</think>Korean').code,
        'ko',
      );
    });

    test('throws when no language can be found', () {
      for (final output in [
        '',
        '{"language": ""}',
        '{"uncertain": true}',
        'I am not sure what language this is, sorry!',
        '{"language": "Elvish-ish (fantasy)"}',
      ]) {
        expect(
          () => ResponseParsers.parseDetectedLanguage(output),
          throwsFormatException,
          reason: output,
        );
      }
    });
  });
}
