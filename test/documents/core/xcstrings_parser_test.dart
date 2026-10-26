// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/xcstrings_parser.dart';

import '../helpers/document_helpers.dart';

const _catalog = '''
{
  "sourceLanguage" : "en",
  "strings" : {
    "%lld items" : {
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "%lld item"
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "%lld items"
                }
              }
            }
          }
        }
      }
    },
    "Brand" : {
      "shouldTranslate" : false
    },
    "Done" : {
      "comment" : "Button title",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Fertig"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Done"
          }
        }
      }
    },
    "Hello %@" : {
      "comment" : "Greeting"
    },
    "Key only" : {

    }
  },
  "version" : "1.0"
}
''';

Map<String, dynamic> _localization(String output, String key, String locale) {
  final json = jsonDecode(output) as Map<String, dynamic>;
  final strings = json['strings'] as Map<String, dynamic>;
  final entry = strings[key] as Map<String, dynamic>;
  final localizations = entry['localizations'] as Map<String, dynamic>;
  return localizations[locale] as Map<String, dynamic>;
}

void main() {
  group('parseXcstrings', () {
    test('round-trips and lists what the target language lacks', () {
      final document = parseXcstrings(_catalog, targetLanguage: 'fr');
      expect(document.format, DocumentFormat.xcstrings);
      expectRoundTrip(document, _catalog);
      expect(texts(document), [
        '⟨1⟩ item',
        '⟨1⟩ items',
        'Done',
        'Hello ⟨1⟩',
        'Key only',
      ]);

      // German already has "Done".
      expect(
        texts(parseXcstrings(_catalog, targetLanguage: 'de')),
        isNot(contains('Done')),
      );
      expect(parseXcstrings(_catalog).isEmpty, isTrue);
      expect(parseXcstrings(_catalog, targetLanguage: 'en').isEmpty, isTrue);
    });

    test('adds the target localisation in Xcode style', () {
      final document = parseXcstrings(_catalog, targetLanguage: 'fr');
      final output = document.render([
        '⟨1⟩ élément',
        '⟨1⟩ éléments',
        'Terminé',
        'Bonjour ⟨1⟩ à 100%',
        'Clé seule',
      ]);
      final json = jsonDecode(output) as Map<String, dynamic>;
      expect(json['version'], '1.0');

      final plural = _localization(output, '%lld items', 'fr');
      expect(plural, {
        'variations': {
          'plural': {
            'many': {
              'stringUnit': {'state': 'needs_review', 'value': '%lld éléments'},
            },
            'one': {
              'stringUnit': {'state': 'needs_review', 'value': '%lld élément'},
            },
            'other': {
              'stringUnit': {'state': 'needs_review', 'value': '%lld éléments'},
            },
          },
        },
      });
      expect(_localization(output, 'Done', 'de'), {
        'stringUnit': {'state': 'translated', 'value': 'Fertig'},
      });
      expect(_localization(output, 'Done', 'fr'), {
        'stringUnit': {'state': 'needs_review', 'value': 'Terminé'},
      });
      expect(
        (_localization(output, 'Hello %@', 'fr')['stringUnit'] as Map)['value'],
        'Bonjour %@ à 100%%',
      );
      expect(_localization(output, 'Key only', 'fr'), isNotNull);
      expect(
        output,
        contains(
          '      "localizations" : {\n'
          '        "de" : {\n'
          '          "stringUnit" : {\n'
          '            "state" : "translated",\n'
          '            "value" : "Fertig"\n'
          '          }\n'
          '        },\n'
          '        "en" : {\n',
        ),
      );
      expect(
        output,
        contains(
          '    "Hello %@" : {\n'
          '      "comment" : "Greeting",\n'
          '      "localizations" : {\n'
          '        "fr" : {\n'
          '          "stringUnit" : {\n'
          '            "state" : "needs_review",\n'
          '            "value" : "Bonjour %@ à 100%%"\n'
          '          }\n'
          '        }\n'
          '      }\n'
          '    },\n',
        ),
      );
      expect(
        output,
        contains('"Brand" : {\n      "shouldTranslate" : false\n    }'),
      );
    });

    test('uses the target plural categories and substitutions', () {
      const catalog = '''
{
  "sourceLanguage" : "en",
  "strings" : {
    "Found %#@files@" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Found %#@files@"
          },
          "substitutions" : {
            "files" : {
              "argNum" : 1,
              "formatSpecifier" : "lld",
              "variations" : {
                "plural" : {
                  "one" : {
                    "stringUnit" : {
                      "state" : "translated",
                      "value" : "%arg file"
                    }
                  },
                  "other" : {
                    "stringUnit" : {
                      "state" : "translated",
                      "value" : "%arg files"
                    }
                  }
                }
              }
            }
          }
        },
        "ja" : {
          "stringUnit" : {
            "state" : "new",
            "value" : ""
          }
        }
      }
    }
  },
  "version" : "1.0"
}
''';
      final document = parseXcstrings(catalog, targetLanguage: 'ja');
      expectRoundTrip(document, catalog);
      expect(texts(document), ['Found ⟨1⟩', '⟨1⟩ file', '⟨1⟩ files']);
      final output = document.render([
        '⟨1⟩が見つかりました',
        '⟨1⟩ 個のファイル',
        '⟨1⟩ 個のファイル',
      ]);
      expect(_localization(output, 'Found %#@files@', 'ja'), {
        'stringUnit': {'state': 'needs_review', 'value': '%#@files@が見つかりました'},
        'substitutions': {
          'files': {
            'argNum': 1,
            'formatSpecifier': 'lld',
            'variations': {
              'plural': {
                'other': {
                  'stringUnit': {
                    'state': 'needs_review',
                    'value': '%arg 個のファイル',
                  },
                },
              },
            },
          },
        },
      });
    });

    test('rejects JSON that is not a string catalogue', () {
      expect(
        () => parseXcstrings('{"a": 1}', targetLanguage: 'de'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parseXcstrings('{"strings": ', targetLanguage: 'de'),
        throwsA(isA<DocumentParseException>()),
      );
    });
  });

  test('inserts before the first locale on one line, odd keys', () {
    const catalog =
        r'{"sourceLanguage":"en","strings":{"Say \"hi\"":{"localizations":'
        '{"fr":{"stringUnit":{"state":"translated","value":"Dis"}}}}},'
        '"version":"1.0"}';
    final document = parseXcstrings(catalog, targetLanguage: 'de');
    expectRoundTrip(document, catalog);
    expect(texts(document), ['Say "hi"']);
    final output = document.render(['Sag "hallo"']);
    final json = jsonDecode(output) as Map<String, dynamic>;
    final strings = json['strings'] as Map<String, dynamic>;
    final entry = strings['Say "hi"'] as Map<String, dynamic>;
    expect((entry['localizations'] as Map).keys, ['de', 'fr']);
  });

  test('inserts a locale before the first one on its own line', () {
    final document = parseXcstrings(_catalog, targetLanguage: 'de');
    final output = document.render([
      for (final segment in document.segments) 'DE ${segment.text}',
    ]);
    final plural = _localization(output, '%lld items', 'de');
    expect(plural['variations'], isNotNull);
    expect(
      output,
      contains(
        '      "localizations" : {\n'
        '        "de" : {\n'
        '          "variations" : {\n',
      ),
    );
    final json = jsonDecode(output) as Map<String, dynamic>;
    final entry =
        (json['strings'] as Map<String, dynamic>)['%lld items']
            as Map<String, dynamic>;
    expect((entry['localizations'] as Map).keys, ['de', 'en']);

    const odd = r'{"a\"b" : 1, "strings" : {"Hi" : {}}}';
    final rendered = parseXcstrings(
      odd,
      targetLanguage: 'fr',
    ).render(['Salut']);
    expect(rendered, contains('"Hi" : {'));
    expect(jsonDecode(rendered), isA<Map<String, dynamic>>());
  });
}
