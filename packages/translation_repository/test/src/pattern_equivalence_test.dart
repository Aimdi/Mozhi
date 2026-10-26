// Reads the private patterns of the parsers with mirrors, to compare them
// with the patterns they replaced without widening the package's API.
import 'dart:math';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:translation_repository/src/prompts/prompt_sanitizer.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';
import 'package:translation_repository/translation_repository.dart';

/// The patterns before they were made linear (they backtrack
/// quadratically or worse on hostile text; see
/// `hostile_input_scaling_test.dart`), kept here only.
abstract final class _Old {
  static const htmlTag =
      r'<!--[\s\S]*?-->|</?[A-Za-z][\w:.-]*(?:\s+[^<>]*?)?\s*/?>';
  static const printf =
      r'%(?:\d+\$)?(?:\([A-Za-z_]\w*\))?[-+ 0#]*\d*(?:\.\d+)?[sdifuxXeEgGcp@]';
  static const printfInText =
      r'%(?:\d+\$)?(?:\([A-Za-z_]\w*\))?[-+0#]*\d*(?:\.\d+)?[sdifuxXeEgGcp@]'
      '(?![A-Za-z])';

  static final RegExp markdown = ProtectedPatterns.combine([
    r'``(?:[^`]|`(?!`))+``|`[^`\n]+`',
    r'!\[[^\]\n]*\]\([^()\s]*(?:\([^()]*\))?[^()\s]*(?:\s+"[^"]*")?\)',
    r'''(?<=\])\((?:[^()\s]|\([^()]*\))*(?:\s+(?:"[^"]*"|'[^']*'|\([^()]*\)))?\)''',
    r'(?<=\])\[[^\]\n]*\]',
    r'\[\^[^\]\n]+\]',
    r'<(?:https?|ftp|mailto):[^<>\s]+>|<[^<>\s@]+@[^<>\s@]+>',
    htmlTag,
    ProtectedPatterns.htmlEntity,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    r'\$\$[^$\n]+\$\$',
  ]);
  static final RegExp json = ProtectedPatterns.combine([
    htmlTag,
    ProtectedPatterns.htmlEntity,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
    printf,
  ]);
  static final RegExp placeholders = ProtectedPatterns.combine([
    ProtectedPatterns.template,
    ProtectedPatterns.braces,
    printfInText,
  ]);
  static final RegExp translation = ProtectedPatterns.combine([
    htmlTag,
    ProtectedPatterns.htmlEntity,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
    ProtectedPatterns.braces,
    printfInText,
  ]);

  // ResponseParsers.
  static final noteEdges = RegExp(
    r'''^[\s"'“”‘’«»*_.…:-]+|[\s"'“”‘’«»*_.…:-]+$''',
  );
  static final meaningKeyEdges = RegExp(r'^[^a-z]+|[^a-z]+$');
  static final edgePunctuation = RegExp(
    '^["\'“”„«»‘’「」『』*]+|["\'“”„«»‘’「」『』*]+\$',
  );
  static final codeEdges = RegExp('^["\'`*]+|["\'`*.]+\$');
  static const _codePattern = '([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*|auto)';
  static const _keyword = r'lang(?:uage)?\s*[:=]\s*';
  static final trailingMarker = RegExp(
    '\\s*\\[\\[\\s*$_keyword$_codePattern\\s*\\]\\]\\s*\$',
    caseSensitive: false,
  );
  static final labelPattern = RegExp(
    r'^\s*(?:(?:sure|okay|ok|certainly|of course)[!,.]?\s*)?'
    r'(?:\*\*|__)?'
    "(?:here(?:'s| is) (?:the |your |my )?(?:translation|translated text|"
    r'rewritten text|improved text)[^\n:：]{0,60}'
    r'|(?:the )?translation(?: in(?:to)? [^\n:：]{1,40}| \([^\n)]{1,40}\))?'
    '|translated text)'
    r'\s*(?:\*\*|__)?\s*[:：]\s*(?:\*\*|__)?[ \t]*(?:\r?\n)?',
    caseSensitive: false,
  );
  static final romanizationLabel = RegExp(
    r'^\s*(?:(?:sure|okay|ok|certainly|of course)[!,.]?\s*)?'
    r'(?:\*\*|__)?'
    "(?:here(?:'s| is) (?:the |your )?)?"
    '(?:romani[sz]ation|romani[sz]ed(?: text| version)?|transliteration'
    '|transliterated text|r[oō]maji|pinyin|jyutping)'
    r'(?: \([^\n)]{1,40}\))?'
    r'\s*(?:\*\*|__)?\s*[:：]\s*(?:\*\*|__)?[ \t]*(?:\r?\n)?',
    caseSensitive: false,
  );
  static final notePattern = RegExp(
    r"^\s*[(\[]?\s*(?:\*\*|__|\*|_)?(?:note|translator'?s? note|n\.b\.)"
    r'(?:\*\*|__|\*|_)?\s*[:：]',
    caseSensitive: false,
  );
  static final jsonFence = RegExp(r'```[\w-]*[ \t]*\r?\n?([\s\S]*?)```');
  static final listSeparator = RegExp(r'\s*[,;、，]\s*');
  static const _thinkTags = 'think|thinking|reasoning|thought';
  static final thinkBlock = RegExp(
    '<($_thinkTags)\\b[^>]*>[\\s\\S]*?</\\1\\s*>',
    caseSensitive: false,
  );
  static final thinkClosing = RegExp(
    '</(?:$_thinkTags)\\s*>',
    caseSensitive: false,
  );
  static final thinkOpening = RegExp(
    '<(?:$_thinkTags)\\b[^>]*>',
    caseSensitive: false,
  );

  /// `ResponseParsers._unwrapTags` as it was.
  static String unwrapTags(String text, String sourceLower) {
    var t = text;
    if (!sourceLower.contains('<translation')) {
      final inner = RegExp(
        r'<translation(?:\s[^>]*)?>([\s\S]*?)</translation>',
        caseSensitive: false,
      ).firstMatch(t);
      if (inner != null && inner.group(1)!.trim().isNotEmpty) {
        t = inner.group(1)!.trim();
      }
    }
    for (final tag in ['translation', 'source', 'target', 'output', 'result']) {
      if (sourceLower.contains('<$tag') || sourceLower.contains('</$tag')) {
        continue;
      }
      t = t
          .replaceFirst(
            RegExp(
              '^\\s*<$tag(?:\\s[^>]*)?>[ \\t]*\\r?\\n?',
              caseSensitive: false,
            ),
            '',
          )
          .replaceFirst(
            RegExp('\\r?\\n?[ \\t]*</$tag>\\s*\$', caseSensitive: false),
            '',
          );
    }
    return t.trim().isEmpty ? text : t;
  }

  /// `ResponseParsers._stripThink` as it was.
  static String stripThink(String text) {
    var s = text.replaceAll(thinkBlock, '');
    final closing = thinkClosing.allMatches(s).lastOrNull;
    if (closing != null) s = s.substring(closing.end);
    final opening = thinkOpening.firstMatch(s);
    if (opening != null) s = s.substring(0, opening.start);
    return s;
  }

  // PromptSanitizer, the personal data shield and MozhiPool.
  static String neutraliseTag(String content, String name) =>
      content.replaceAll(
        RegExp(
          '<(?=\\s*/?\\s*${RegExp.escape(name)}(?![\\w-]))',
          caseSensitive: false,
        ),
        '<${PromptSanitizer.zeroWidthSpace}',
      );
  static final partialToken = RegExp(r'[⟨〈]\s*\d{0,6}\s*$');
  static final url = RegExp(
    r'''\b[a-z][a-z0-9+.-]*://[^\s"'<>]+''',
    caseSensitive: false,
  );

  /// `MozhiPool.sanitizeMessage` as it was.
  static String sanitizeMessage(String message) {
    var text = message.replaceAllMapped(url, (match) {
      final uri = Uri.tryParse(match[0]!);
      if (uri == null || uri.host.isEmpty) return '<url>';
      return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    });
    if (text.length > MozhiPool.maxMessageLength) {
      text =
          '${text.substring(0, MozhiPool.maxMessageLength - 1).trimRight()}…';
    }
    return text;
  }
}

/// A private static member of [type] (a field's value, or [arguments]
/// passed to a method).
Object? _private(Type type, String name, [List<Object?>? arguments]) =>
    _privateOf(reflectClass(type), name, arguments);

Object? _privateOf(ClassMirror type, String name, [List<Object?>? arguments]) {
  final symbol = MirrorSystem.getSymbol(name, type.owner! as LibraryMirror);
  return arguments == null
      ? type.getField(symbol).reflectee
      : type.invoke(symbol, arguments).reflectee;
}

/// The private class [name] of the library that declares [type].
ClassMirror _privateClass(Type type, String name) {
  final library = reflectClass(type).owner! as LibraryMirror;
  return library.declarations[MirrorSystem.getSymbol(name, library)]!
      as ClassMirror;
}

/// [match] and its groups.
String _describe(RegExpMatch match) =>
    '${match.start}-${match.end} '
    '${[for (var i = 1; i <= match.groupCount; i++) match.group(i)]}';

/// Where [pattern] matches in [text], with its groups.
List<String> _matches(RegExp pattern, String text) => [
  for (final match in pattern.allMatches(text)) _describe(match),
];

String? _first(RegExp pattern, String text) {
  final match = pattern.firstMatch(text);
  return match == null ? null : _describe(match);
}

/// Texts of up to [length] of [tokens], the same every run.
Iterable<String> _texts(
  List<String> tokens, {
  int count = 20000,
  int length = 10,
  int seed = 1,
}) sync* {
  final random = Random(seed);
  for (var i = 0; i < count; i++) {
    yield [
      for (var n = random.nextInt(length + 1); n > 0; n--)
        tokens[random.nextInt(tokens.length)],
    ].join();
  }
}

/// Expects [actual] to give what [expected] gives on each of [texts]
/// (those that [unless] holds for are skipped).
void _expectSame(
  Iterable<String> texts,
  Object? Function(String text) expected,
  Object? Function(String text) actual, {
  bool Function(String text)? unless,
}) {
  var compared = 0;
  for (final text in texts) {
    if (unless != null && unless(text)) continue;
    compared++;
    expect(actual(text), expected(text), reason: text);
  }
  expect(compared, greaterThan(0));
}

int _count(String text, String part) => part.allMatches(text).length;

/// Texts where a comment could hold another `<!--`, or an image
/// description `![` or a footnote label `[^` (see the differences below).
bool _nested(String text) =>
    _count(text, '<!--') > 1 ||
    _count(text, '![') > 1 ||
    _count(text, '[^') > 1;

void main() {
  final markup = [
    '<!--', '-->', '<', '>', '/', '!', '-', 'a', 'B', ' ', '\n', '\t', ':', //
    '.', '=', '"', '<a', '</a', '<x:y', '/>', '<br', '<!', '<1', '&amp;',
  ];
  final conversions = [
    '%', '0', '1', '9', r'$', '.', '-', '+', ' ', '#', '(', ')', 'a', '_', //
    's', 'd', 'x', '@', 'l', 'X', 'z', '%%', '%0', '%1',
  ];
  final markdown = [
    '![', '[^', '[', ']', '(', ')', '!', '^', 'a', ' ', '\n', '"', "'", //
    '`', '``', r'$$', '<', '>', 'http://a.b', 'a@b.de', '<!--', '-->', //
    '<a>', '&amp;', 'www.x.de', '](', '1',
  ];
  final mixed = [
    ...markup, ...conversions, '{{', '}}', '{', '}', r'${', r'$t(', '@:', //
    'a@b.de', 'www.x.de', '&#160;', '&', ';',
  ];

  group('ProtectedPatterns match what the old patterns matched', () {
    test('htmlTag', () {
      _expectSame(
        [
          '<b>bold</b> and <a href="x">link</a> <br/> <br /> <img alt=x>',
          '<p\nclass="x"> <a/b> <x:y z="1"> </ b> <1a> < a> <a\t>',
          '<!-- note --> text <!----> <!-- a -- b --> <a <b> <!-->',
          ..._texts(markup, length: 12),
        ],
        (text) => _matches(RegExp(_Old.htmlTag), text),
        (text) => _matches(RegExp(ProtectedPatterns.htmlTag), text),
        unless: _nested,
      );
    });

    test('printf and printfInText', () {
      final texts = [
        r'%05d %-05d %00012d %1$05.2f %(n)05d %s %.2f %10s %0s %+0#5x %%',
        r'50%off 100% done %1$sMB %@x %lld %(name)s',
        ..._texts(conversions, length: 12),
      ];
      _expectSame(
        texts,
        (text) => _matches(RegExp(_Old.printf), text),
        (text) => _matches(RegExp(ProtectedPatterns.printf), text),
      );
      _expectSame(
        texts,
        (text) => _matches(RegExp(_Old.printfInText), text),
        (text) => _matches(RegExp(ProtectedPatterns.printfInText), text),
      );
    });

    test('markdown', () {
      _expectSame(
        [
          'see ![alt](img.png) and ![a](b(c)d "t") [^1] [x](y) <http://a.b>',
          r'<a@b.c> $$x$$ `code` ``co`de`` [a](b) ![x](y) ![a[b](x) [^a [b]',
          'mail me: a.b@example.com, www.example.com/x. https://a.b/(c)',
          ..._texts(markdown, count: 40000, length: 12),
        ],
        (text) => _matches(_Old.markdown, text),
        (text) => _matches(ProtectedPatterns.markdown, text),
        unless: _nested,
      );
    });

    test('json, placeholders and translation', () {
      final texts = [
        r'&amp; &#160; &#x2014; {{name}} ${x} $t(key) @:key {0} {name}',
        r'Hi <b>{{n}}</b> %1$s %05d a@b.de www.x.de/y 😀',
        ..._texts(mixed, length: 12),
      ];
      for (final (old, pattern) in [
        (_Old.json, ProtectedPatterns.json),
        (_Old.placeholders, ProtectedPatterns.placeholders),
        (_Old.translation, ProtectedPatterns.translation),
      ]) {
        _expectSame(
          texts,
          (text) => _matches(old, text),
          (text) => _matches(pattern, text),
          unless: _nested,
        );
      }
    });

    test('differ only on nested openers', () {
      List<String> spans(RegExp pattern, String text) => [
        for (final match in pattern.allMatches(text)) match[0]!,
      ];
      // A comment never contains `<!--`.
      expect(spans(RegExp(_Old.htmlTag), '<!-- a <!-- b -->'), [
        '<!-- a <!-- b -->',
      ]);
      expect(spans(RegExp(ProtectedPatterns.htmlTag), '<!-- a <!-- b -->'), [
        '<!-- b -->',
      ]);
      // An image description never contains `![`.
      expect(spans(_Old.markdown, '![a ![b](c)](d)'), ['![a ![b](c)', '(d)']);
      expect(spans(ProtectedPatterns.markdown, '![a ![b](c)](d)'), [
        '![b](c)',
        '(d)',
      ]);
      // A footnote label never contains `[^`.
      expect(spans(_Old.markdown, '[^a [^b]'), ['[^a [^b]']);
      expect(spans(ProtectedPatterns.markdown, '[^a [^b]'), ['[^b]']);
      // Other brackets are kept as they were.
      for (final text in ['![a[b](x)', '[^a [b]', '![a !b](c)']) {
        expect(
          spans(ProtectedPatterns.markdown, text),
          spans(_Old.markdown, text),
        );
      }
    });
  });

  group('ResponseParsers cleans up what it did before', () {
    RegExp pattern(String name) => _private(ResponseParsers, name)! as RegExp;
    String replaceAll(RegExp pattern, String text) =>
        text.replaceAll(pattern, '');
    final edges = [
      ' ', '\n', '"', "'", '“', '*', '_', '.', '…', ':', '-', 'a', 'B', //
      '1', '!', '«', '」', '`', '}',
    ];

    test('edge characters', () {
      for (final (old, name) in [
        (_Old.noteEdges, '_noteEdges'),
        (_Old.meaningKeyEdges, '_meaningKeyEdges'),
        (_Old.edgePunctuation, '_edgePunctuation'),
        (_Old.codeEdges, '_codeEdges'),
      ]) {
        final current = pattern(name);
        _expectSame(
          _texts(edges),
          (text) => replaceAll(old, text),
          (text) => replaceAll(current, text),
        );
      }
    });

    test('trailing language markers', () {
      final current = pattern('_trailingMarker');
      _expectSame(
        _texts([
          ' ', '\n', '\t', '[[', ']]', '[', ']', 'lang', 'language', ':', //
          '=', 'fr', 'de-AT', 'auto', 'x', '_', '-', 'en',
        ], length: 12),
        (text) => _first(_Old.trailingMarker, text),
        (text) => _first(current, text),
      );
    });

    test('labels and notes', () {
      final texts = _texts(
        [
          ' ', '\n', '\t', '**', '__', '*', '_', ':', '：', 'sure', 'Sure!', //
          'here is ', "here's ", 'the ', 'your ', 'my ', 'translation', //
          'translated text', ' into ', ' in ', 'French', '(', ')', ' (', 'x',
          '\r\n', 'romanization', 'pinyin', 'romanized', ' text', 'note', //
          'Note', '[', 'N.B.', "translator's note",
        ],
        count: 40000,
        length: 9,
      ).toList();
      for (final (old, name) in [
        (_Old.labelPattern, '_labelPattern'),
        (_Old.romanizationLabel, '_romanizationLabel'),
        (_Old.notePattern, '_notePattern'),
      ]) {
        final current = pattern(name);
        _expectSame(
          texts,
          (text) => _first(old, text),
          (text) => _first(current, text),
        );
      }
    });

    test('JSON fences', () {
      final current = pattern('_jsonFence');
      _expectSame(
        _texts([
          '```', '`', 'json', '-', '_', ' ', '\t', '\r', '\n', '{', '}', //
          'a', '1', '"',
        ], length: 12),
        (text) => _matches(_Old.jsonFence, text),
        (text) => _matches(current, text),
      );
    });

    test('list items', () {
      final current = pattern('_listSeparator');
      List<String> items(RegExp separator, String text) => [
        for (final part in text.split(separator))
          if (part.trim().isNotEmpty) part.trim(),
      ];
      _expectSame(
        _texts([
          ' ',
          '\n',
          ',',
          ';',
          '、',
          '，',
          'a',
          'b c',
          '\u00a0',
          '\u0085',
          '\t',
        ]),
        (text) => items(_Old.listSeparator, text),
        (text) => items(current, text),
      );
    });

    test('wrapper tags', () {
      final texts = _texts([
        '<translation>', '</translation>', '<TRANSLATION', ' ', '\n', //
        '>', '<', 'a', 'x="1"', '</Translation>', '<translation ', //
        '<translationx>', '\t', '/', '<source>', '</source>', '\r\n',
      ], count: 40000);
      for (final source in ['', '<translation>', '<source>']) {
        _expectSame(
          texts,
          (text) => _Old.unwrapTags(text, source),
          (text) => _private(ResponseParsers, '_unwrapTags', [text, source]),
        );
      }
    });

    test('reasoning blocks', () {
      _expectSame(
        _texts([
          '<think>', '</think>', '<THINK ', '</Think >', '<thinking>', //
          '</thinking>', '<thought>', '</thought>', '<reasoning a="b">',
          '</reasoning>', '<thinker>', '>', '<', ' ', 'a', '\n', //
          '</think', '<think',
        ], count: 40000),
        _Old.stripThink,
        (text) => _private(ResponseParsers, '_stripThink', [text]),
      );
    });
  });

  group('prompts, the shield and server errors work as before', () {
    test('defused tags', () {
      _expectSame(
        _texts([
          '<', '/', ' ', '\n', 'source', 'SOURCE', 'sources', 'source-x', //
          '>', 'a', '\t',
        ]),
        (text) => _Old.neutraliseTag(text, 'source'),
        (text) => PromptSanitizer.neutraliseTag(text, 'source'),
      );
    });

    test('partial tokens', () {
      final current =
          _privateOf(
                _privateClass(TranslationRepository, '_Shield'),
                '_partialToken',
              )!
              as RegExp;
      _expectSame(
        _texts(['⟨', '〈', ' ', '\n', '1', '12', '1234567', 'a', '⟩']),
        (text) => _first(_Old.partialToken, text),
        (text) => _first(current, text),
      );
    });

    test('URLs in server error messages', () {
      _expectSame(
        _texts(
          [
            'a', 'B', '1', '.', '+', '-', '_', '://', 'x', ' ', '"', '<', //
            '/', '?q=1', ':', 'https', 'ftp', 'é', '%20', ':80',
          ],
          count: 40000,
          length: 12,
        ),
        _Old.sanitizeMessage,
        MozhiPool.sanitizeMessage,
      );
    });
  });
}
