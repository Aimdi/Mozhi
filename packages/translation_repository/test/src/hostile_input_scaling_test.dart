import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/prompts/prompt_sanitizer.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

/// About the size of each hostile input, in characters (ten times what the
/// translate screen takes).
const _size = 200000;

/// Each entry point handles each input within this. The linear code takes
/// well under a second on a desktop and a few times longer on a shared CI
/// runner; a regular expression that backtracks quadratically takes
/// minutes on such inputs, one that backtracks cubically (the old
/// `ProtectedPatterns.htmlTag` on `<a` and spaces) days.
const _budget = Duration(seconds: 5);

/// How long the inputs of one test may take before it fails as stuck: a
/// running regular expression cannot be interrupted, so the work runs in
/// an isolate, which a stuck test leaves behind.
const _stuck = Duration(seconds: 40);

String _many(String text) => text * (_size ~/ text.length);

/// Texts that make a backtracking regular expression engine scan a run of
/// characters again from each position in it, for the patterns of this
/// package: unclosed markup, long runs of spaces, digits, zeros, dots and
/// openers.
final Map<String, String> _hostile = {
  'a tag followed by spaces': '<a${' ' * _size}',
  'a closing tag followed by line breaks': '</a${'\n' * _size}x',
  'a tag followed by spaces and a slash': '<a${' ' * _size}/',
  'unclosed comments': _many('<!--'),
  'a comment followed by unclosed comments': '<!-- ${_many('<!-- a ')}',
  'unclosed tags': _many('<a '),
  'a conversion with zeros': '%${'0' * _size}!',
  'a positional conversion with zeros': '%1\$${'0' * _size}!',
  'a named conversion with zeros': '%(a)${'0' * _size}!',
  'a conversion with digits': '%${'1' * _size}!',
  'a conversion with flags': '%${'-' * _size}!',
  'a conversion with a long name': '%(${'a' * _size}!',
  'conversion openers': _many('%0'),
  'footnote openers': _many('[^'),
  'image openers': _many('!['),
  'footnote and image openers': 'Hi ${_many('[^![')}',
  'image openers before a bracket': '${_many('![')}]',
  'an image with a long destination': '![](${'a' * _size}',
  'link openers': _many(']('),
  'code span openers': _many('``a'),
  'unclosed code fences': _many('```a'),
  'math openers': _many(r'$$a'),
  'template openers': _many('{{a'),
  'an entity with many digits': '&#${'1' * _size}',
  'a URL of dots': 'www.${'.' * _size}',
  'an e-mail address of dashes': 'a@${'-' * _size}!',
  'an e-mail address of numeric labels': 'a@b${_many('.1')}!',
  'e-mail addresses without a domain': _many('a@'),
  'spaces': 'a${' ' * _size}x',
  'line breaks': 'a${'\n' * _size}x',
  'dots': 'a${'.' * _size}x',
  'quotes and stars': 'a${_many('"*')}x',
  'digits with spaces': _many('1 '),
  'letters and digits': 'a${'1' * _size}!',
  'Han characters': _many('中)'),
  'an opening bracket and spaces': '(${' ' * _size}x',
  'bracket tokens with spaces': '⟨${' ' * _size}x',
  'XML tokens with spaces': '<x${' ' * _size}i',
};

/// Model output that the reply parsers look into.
final Map<String, String> _replies = {
  'unclosed translation tags': _many('<translation>'),
  'translation tags without an end': _many('<translation '),
  'a closing translation tag after spaces': 'a${' ' * _size}</translation>x',
  'a label followed by spaces': 'Translation${' ' * _size}x',
  'a label followed by line breaks': 'Here is the translation${'\n' * _size}x',
  'a romanization label followed by spaces': 'Romanization${' ' * _size}x',
  'a note paragraph of spaces': 'a\n\n${' ' * _size}x',
  'a marker opener followed by spaces': '[[${' ' * _size}x',
  'a trailing marker after spaces': 'a${' ' * _size}[[lang:fr]]',
  'unclosed think blocks': '${_many('<think>')}{"a": 1}',
  'think tags without an end': '${_many('<think ')}>{"a": 1}',
  'an unclosed fence with a long info string': '```${'a' * _size}{"a": 1}',
  'an unclosed fence with spaces': '```${' ' * _size}{"a": 1}',
};

/// Bracket-heavy model output for the JSON search, where each opening
/// bracket may start a candidate: brackets that never close, nested ones
/// that never decode, and open brackets with many commas (the places a
/// truncated reply is cut at).
final Map<String, String> _brackets = {
  'unclosed brackets': _many('['),
  'unclosed braces': _many('{'),
  'unclosed objects': _many('{"a":'),
  'unclosed lists of objects': _many('[{"a":'),
  'unclosed strings in brackets': _many('["'),
  'unclosed objects in strings': _many('{"{'),
  'nested lists': '${'[' * (_size ~/ 2)}${']' * (_size ~/ 2)}',
  'nested objects that do not decode':
      '${_many('{"a":')}x${'}' * (_size ~/ 5)}',
  'nested lists before an object': '${'[' * _size}{"a": 1}',
  'open brackets with commas': '${'[' * (_size ~/ 2)}${',' * (_size ~/ 2)}',
  'open objects with commas': '{"a": [${_many('1, ')}',
  'closed lists without objects': _many('[1, [2]] '),
  'unclosed lists of words': _many('[x '),
  'mismatched brackets': _many('[1}'),
  'unclosed lists with quotes': _many('["a '),
  'nested lists that do not decode before an object':
      '${'[x ' * (_size ~/ 6)}{"a": 1}${']' * (_size ~/ 6)}',
};

/// [names] of [_hostile] and [_replies].
Map<String, String> _pick(List<String> names) => {
  for (final name in names) name: _hostile[name] ?? _replies[name]!,
};

/// Expects [run] to handle each of [inputs] (all of [_hostile] when null)
/// within [_budget], in a new isolate. Each input is first run cut short,
/// so that compiling the patterns is not timed, and timed again when it
/// takes longer (in case something else slowed it down).
void _scales(
  String description,
  void Function(String text) run, {
  Map<String, String>? inputs,
}) {
  test(description, () async {
    final texts = inputs ?? _hostile;
    final elapsed = await Isolate.run(() {
      return {
        for (final MapEntry(key: name, value: text) in texts.entries)
          name: _time(text, run),
      };
    }).timeout(_stuck, onTimeout: () => fail('stuck for $_stuck'));
    for (final MapEntry(key: name, value: time) in elapsed.entries) {
      expect(time, lessThan(_budget), reason: name);
    }
  }, timeout: Timeout(_stuck * 2));
}

Duration _time(String text, void Function(String text) run) {
  Duration once() {
    final watch = Stopwatch()..start();
    run(text);
    return watch.elapsed;
  }

  run(text.substring(0, 100));
  final first = once();
  if (first < _budget) return first;
  final second = once();
  return second < first ? second : first;
}

/// [parse], which throws [FormatException] for no answer, without it.
void _parse(Object? Function() parse) {
  try {
    parse();
  } on FormatException {
    // No JSON in the reply.
  }
}

void _check(String source, String output) => TranslationQa.check(
  source: source,
  output: output,
  sourceLanguage: english,
  target: german,
  glossary: const {'new york': 'New York'},
  ai: true,
);

/// A reply with [text] in every field the JSON parsers clean up.
String _fields(String text) => jsonEncode({
  'language': text,
  'verdict': text,
  'issues': [
    text,
    {'type': text, 'source': text, 'target': text},
  ],
  'pairs': [
    {'source': text, 'target': text},
  ],
  'word': 'x',
  'synonyms': text,
});

void main() {
  group('ProtectedPatterns take linear time on hostile text', () {
    final patterns = <String, RegExp Function()>{
      'htmlTag': () => ProtectedPatterns.combine([ProtectedPatterns.htmlTag]),
      'htmlEntity': () =>
          ProtectedPatterns.combine([ProtectedPatterns.htmlEntity]),
      'url': () => ProtectedPatterns.combine([ProtectedPatterns.url]),
      'email': () => ProtectedPatterns.combine([ProtectedPatterns.email]),
      'printf': () => ProtectedPatterns.combine([ProtectedPatterns.printf]),
      'printfInText': () =>
          ProtectedPatterns.combine([ProtectedPatterns.printfInText]),
      'template': () => ProtectedPatterns.combine([ProtectedPatterns.template]),
      'braces': () => ProtectedPatterns.combine([ProtectedPatterns.braces]),
      'plainText': () => ProtectedPatterns.plainText,
      'subtitle': () => ProtectedPatterns.subtitle,
      'markdown': () => ProtectedPatterns.markdown,
      'json': () => ProtectedPatterns.json,
      'placeholders': () => ProtectedPatterns.placeholders,
      'translation': () => ProtectedPatterns.translation,
    };
    for (final MapEntry(key: name, value: pattern) in patterns.entries) {
      _scales(name, (text) => pattern().allMatches(text).length);
    }
  });

  group('the translate screen takes linear time on hostile text', () {
    _scales('TextMasker masks and restores', (text) {
      final spans = TextMasker.formatSpans(text);
      for (final style in MaskStyle.values) {
        final masked = TextMasker.mask(text, spans, style: style);
        masked
          ..restore(masked.text)
          ..restore(text);
      }
    });

    // The checks make a dozen passes over each text.
    final checked = _pick([
      'a tag followed by spaces',
      'unclosed comments',
      'a conversion with zeros',
      'a named conversion with zeros',
      'code span openers',
      'unclosed code fences',
      'a URL of dots',
      'an e-mail address of dashes',
      'digits with spaces',
      'spaces',
      'Han characters',
      'bracket tokens with spaces',
    ]);
    _scales(
      'TranslationQa checks a source',
      (text) => _check(text, 'Hallo 12 Welt, wie geht es?'),
      inputs: checked,
    );
    _scales(
      'TranslationQa checks a translation',
      (text) => _check('Hello 12 world, how are you?', text),
      inputs: checked,
    );

    _scales('PersonalData finds personal data', PersonalData.find);

    _scales(
      'prompts defuse tags',
      (text) {
        PromptSanitizer.neutraliseTag(text, 'source');
        TranslationPrompts.translate(
          TranslationRequest(text: text, source: english, target: german),
        );
      },
      inputs: {
        ..._hostile,
        'tag openers with spaces': _many('< '),
        'a tag opener followed by spaces': '<${' ' * _size}/ x',
      },
    );
  });

  group('model output takes linear time to parse', () {
    final general = [
      'a tag followed by spaces',
      'unclosed comments',
      'spaces',
      'line breaks',
      'dots',
      'quotes and stars',
      'Han characters',
    ];
    final replies = _pick([...general, ..._replies.keys]);

    _scales(
      'cleanTranslation',
      (text) => ResponseParsers.cleanTranslation(text, source: 'Hello'),
      inputs: replies,
    );
    _scales(
      'cleanRomanization',
      (text) => ResponseParsers.cleanRomanization(text, source: 'こんにちは'),
      inputs: replies,
    );
    _scales('language markers', (text) {
      ResponseParsers.splitLanguageMarker(text);
      ResponseParsers.isMarkerPending(text);
    }, inputs: replies);
    _scales(
      'extractJsonObject',
      (text) => _parse(() => ResponseParsers.extractJsonObject(text)),
      inputs: replies,
    );
    _scales(
      'parseDetectedLanguage',
      (text) => _parse(() => ResponseParsers.parseDetectedLanguage(text)),
      inputs: replies,
    );
    _scales(
      'extractJsonObject on brackets',
      (text) => _parse(() => ResponseParsers.extractJsonObject(text)),
      inputs: _brackets,
    );
    _scales(
      'parseMeaningCheck on brackets',
      (text) => _parse(
        () => ResponseParsers.parseMeaningCheck(
          text,
          source: 'Hello',
          translation: 'Hallo',
        ),
      ),
      inputs: _brackets,
    );

    final fields = {
      for (final MapEntry(key: name, value: text) in _pick([
        ...general,
        'a marker opener followed by spaces',
        'a trailing marker after spaces',
        'digits with spaces',
      ]).entries)
        name: _fields(text),
    };
    _scales(
      'parseDetectedLanguage fields',
      (json) => _parse(() => ResponseParsers.parseDetectedLanguage(json)),
      inputs: fields,
    );
    _scales(
      'parseMeaningCheck fields',
      (json) => _parse(
        () => ResponseParsers.parseMeaningCheck(
          json,
          source: json,
          translation: json,
        ),
      ),
      inputs: fields,
    );
    _scales(
      'parseAlignment fields',
      (json) => _parse(
        () => ResponseParsers.parseAlignment(
          json,
          source: json,
          translation: json,
        ),
      ),
      inputs: fields,
    );
    _scales(
      'parseDictionary fields',
      (json) => _parse(() => ResponseParsers.parseDictionary(json, query: 'x')),
      inputs: fields,
    );

    _scales(
      'server error messages',
      MozhiPool.sanitizeMessage,
      inputs: {
        ..._hostile,
        'dotted words': 'x ${_many('a.')}',
        'words with plus signs': 'x ${_many('a+')}',
      },
    );

    test('streamed replies with the personal data shield', () async {
      final elapsed = await Isolate.run(() async {
        registerTestFallbacks();
        final client = MockLlmClient();
        final repository =
            allowNetwork(
              TranslationRepository(
                llmClientFactory: (_) => client,
                snapshotInterval: Duration.zero,
              ),
            )..updateConfiguration(
              instances: const [],
              providers: const [claudeConfig],
            );
        final times = <String, Duration>{};
        for (final MapEntry(key: name, value: text) in {
          'a token opener followed by spaces': 'Mail ⟨${' ' * _size}x',
          'a token opener followed by line breaks': 'Mail ⟨${'\n' * _size}',
          'a token opener with digits and spaces': 'Mail ⟨ 1${' ' * _size}x',
        }.entries) {
          when(() => client.streamChat(any()))
              .thenAnswer((_) => Stream.fromIterable([text, ' ⟨', '1⟩']));
          final watch = Stopwatch()..start();
          final reply = await repository
              .explain(
                aiEngine(claudeConfig),
                const TranslationRequest(
                  text: 'Write to jane@x.org.',
                  source: english,
                  target: german,
                ),
                'Schreib an jane@x.org.',
              )
              .join();
          times[name] = watch.elapsed;
          if (!reply.endsWith(' jane@x.org')) times[name] = _stuck;
        }
        repository.dispose();
        return times;
      }).timeout(_stuck, onTimeout: () => fail('stuck for $_stuck'));
      for (final MapEntry(key: name, value: time) in elapsed.entries) {
        expect(time, lessThan(_budget), reason: name);
      }
    }, timeout: Timeout(_stuck * 2));

    test(
      'streamed replies with the personal data shield, a space at a time',
      () async {
        final elapsed = await Isolate.run(() async {
          registerTestFallbacks();
          final client = MockLlmClient();
          final repository =
              allowNetwork(
                TranslationRepository(
                  llmClientFactory: (_) => client,
                  snapshotInterval: Duration.zero,
                ),
              )..updateConfiguration(
                instances: const [],
                providers: const [claudeConfig],
              );
          // A token's start held back while a long run of spaces streams
          // in, one delta each (the held text is not read again).
          final spaces = List.filled(_size, ' ');
          final times = <String, Duration>{};
          for (final MapEntry(key: name, value: deltas) in {
            'spaces after a token opener': ['Mail ⟨', ...spaces, '1⟩'],
            'spaces after a token number': ['Mail ⟨1', ...spaces, '⟩'],
            'spaces on both sides': ['Mail ⟨', ...spaces, '1', ...spaces, '⟩'],
            'line breaks after a token number': [
              'Mail ⟨1',
              ...List.filled(_size, '\n'),
              '⟩',
            ],
          }.entries) {
            when(() => client.streamChat(any()))
                .thenAnswer((_) => Stream.fromIterable(deltas));
            final watch = Stopwatch()..start();
            final reply = await repository
                .explain(
                  aiEngine(claudeConfig),
                  const TranslationRequest(
                    text: 'Write to jane@x.org.',
                    source: english,
                    target: german,
                  ),
                  'Schreib an jane@x.org.',
                )
                .join();
            times[name] = watch.elapsed;
            if (reply != 'Mail jane@x.org') times[name] = _stuck;
          }
          repository.dispose();
          return times;
        }).timeout(_stuck, onTimeout: () => fail('stuck for $_stuck'));
        for (final MapEntry(key: name, value: time) in elapsed.entries) {
          expect(time, lessThan(_budget), reason: name);
        }
      },
      timeout: Timeout(_stuck * 2),
    );
  });
}
