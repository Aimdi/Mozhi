/// Language tags, plural rules and placeholder patterns shared by the
/// localisation file parsers (PO, XLIFF, Android, Apple, xcstrings).
library;

import 'package:mozhi/documents/core/parsers/markup_lexer.dart';
import 'package:translation_repository/translation_repository.dart'
    show ProtectedPatterns;

// ---------------------------------------------------------------------------
// Language tags
// ---------------------------------------------------------------------------

final _tag = RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$');

/// [code] as a well-formed BCP 47 tag in canonical case (`pt_br` ->
/// `pt-BR`, `zh-hans` -> `zh-Hans`), or null when it is not one (e.g. a
/// custom AI "language" such as "Pirate speak").
String? canonicalLanguageTag(String? code) {
  if (code == null) return null;
  final value = code.trim().replaceAll('_', '-');
  if (!_tag.hasMatch(value)) return null;
  final parts = value.split('-');
  return [
    asciiLower(parts.first),
    for (final part in parts.skip(1))
      if (part.length == 4 && RegExp(r'^[A-Za-z]{4}$').hasMatch(part))
        '${part[0].toUpperCase()}${asciiLower(part.substring(1))}'
      else if (part.length == 2 || RegExp(r'^\d{3}$').hasMatch(part))
        part.toUpperCase()
      else
        asciiLower(part),
  ].join('-');
}

/// Whether [a] and [b] name the same language for the purpose of keeping
/// existing translations: equal tags, or the same language where one of
/// them has no region or script (`de` and `de-DE`).
bool sameLanguage(String a, String b) {
  final x = canonicalLanguageTag(a);
  final y = canonicalLanguageTag(b);
  if (x == null || y == null) {
    return asciiLower(a.trim()) == asciiLower(b.trim());
  }
  if (x == y) return true;
  final xs = x.split('-');
  final ys = y.split('-');
  return xs.first == ys.first && (xs.length == 1 || ys.length == 1);
}

const _rtl = {
  'ar',
  'he',
  'iw',
  'fa',
  'ur',
  'ps',
  'sd',
  'ug',
  'ckb',
  'dv',
  'yi',
};

/// Whether [tag] is written right to left.
bool isRightToLeft(String tag) {
  final canonical = canonicalLanguageTag(tag);
  if (canonical == null) return false;
  final parts = canonical.split('-');
  if (parts.contains('Arab') || parts.contains('Hebr')) return true;
  if (parts.contains('Latn') || parts.contains('Cyrl')) return false;
  return _rtl.contains(parts.first);
}

// ---------------------------------------------------------------------------
// Plural rules
// ---------------------------------------------------------------------------

const _otherOnly = ['other'];
const _oneOther = ['one', 'other'];
const _oneManyOther = ['one', 'many', 'other'];
const _slavic = ['one', 'few', 'many', 'other'];
const _oneFewOther = ['one', 'few', 'other'];

/// CLDR cardinal plural categories by language (CLDR 44).
const Map<String, List<String>> _categories = {
  'ja': _otherOnly,
  'zh': _otherOnly,
  'ko': _otherOnly,
  'vi': _otherOnly,
  'th': _otherOnly,
  'id': _otherOnly,
  'ms': _otherOnly,
  'lo': _otherOnly,
  'km': _otherOnly,
  'my': _otherOnly,
  'jv': _otherOnly,
  'su': _otherOnly,
  'bo': _otherOnly,
  'dz': _otherOnly,
  'ig': _otherOnly,
  'yo': _otherOnly,
  'wo': _otherOnly,
  'to': _otherOnly,
  'yue': _otherOnly,
  'en': _oneOther,
  'de': _oneOther,
  'nl': _oneOther,
  'sv': _oneOther,
  'da': _oneOther,
  'nb': _oneOther,
  'nn': _oneOther,
  'no': _oneOther,
  'fi': _oneOther,
  'et': _oneOther,
  'el': _oneOther,
  'hu': _oneOther,
  'tr': _oneOther,
  'bg': _oneOther,
  'eu': _oneOther,
  'gl': _oneOther,
  'af': _oneOther,
  'sq': _oneOther,
  'az': _oneOther,
  'kk': _oneOther,
  'ky': _oneOther,
  'uz': _oneOther,
  'ka': _oneOther,
  'mn': _oneOther,
  'ne': _oneOther,
  'ur': _oneOther,
  'sw': _oneOther,
  'ta': _oneOther,
  'te': _oneOther,
  'ml': _oneOther,
  'kn': _oneOther,
  'mr': _oneOther,
  'bn': _oneOther,
  'hi': _oneOther,
  'gu': _oneOther,
  'pa': _oneOther,
  'as': _oneOther,
  'or': _oneOther,
  'fa': _oneOther,
  'hy': _oneOther,
  'am': _oneOther,
  'si': _oneOther,
  'is': _oneOther,
  'mk': _oneOther,
  'fy': _oneOther,
  'eo': _oneOther,
  'zu': _oneOther,
  'ha': _oneOther,
  'ckb': _oneOther,
  'lb': _oneOther,
  'fo': _oneOther,
  'fil': _oneOther,
  'tl': _oneOther,
  'fr': _oneManyOther,
  'es': _oneManyOther,
  'it': _oneManyOther,
  'pt': _oneManyOther,
  'ca': _oneManyOther,
  'he': ['one', 'two', 'other'],
  'iw': ['one', 'two', 'other'],
  'ru': _slavic,
  'uk': _slavic,
  'be': _slavic,
  'pl': _slavic,
  'lt': _slavic,
  'cs': _slavic,
  'sk': _slavic,
  'sr': _oneFewOther,
  'hr': _oneFewOther,
  'bs': _oneFewOther,
  'ro': _oneFewOther,
  'lv': ['zero', 'one', 'other'],
  'sl': ['one', 'two', 'few', 'other'],
  'gd': ['one', 'two', 'few', 'other'],
  'ga': ['one', 'two', 'few', 'many', 'other'],
  'ar': ['zero', 'one', 'two', 'few', 'many', 'other'],
  'cy': ['zero', 'one', 'two', 'few', 'many', 'other'],
};

/// The CLDR plural categories [tag] uses, or null for a language this
/// table does not know.
List<String>? pluralCategories(String? tag) {
  final canonical = canonicalLanguageTag(tag);
  if (canonical == null) return null;
  return _categories[canonical.split('-').first];
}

const _single = 'nplurals=1; plural=0;';
const _notOne = 'nplurals=2; plural=(n != 1);';
const _moreThanOne = 'nplurals=2; plural=(n > 1);';
const _eastSlavic =
    'nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && '
    '(n%100<10 || n%100>=20) ? 1 : 2);';

/// gettext `Plural-Forms` by language (as msginit writes them).
const Map<String, String> _pluralForms = {
  'ja': _single,
  'zh': _single,
  'ko': _single,
  'vi': _single,
  'th': _single,
  'id': _single,
  'ms': _single,
  'lo': _single,
  'km': _single,
  'my': _single,
  'jv': _single,
  'su': _single,
  'bo': _single,
  'dz': _single,
  'ig': _single,
  'yo': _single,
  'wo': _single,
  'to': _single,
  'yue': _single,
  'en': _notOne,
  'de': _notOne,
  'nl': _notOne,
  'sv': _notOne,
  'da': _notOne,
  'nb': _notOne,
  'nn': _notOne,
  'no': _notOne,
  'fi': _notOne,
  'et': _notOne,
  'el': _notOne,
  'hu': _notOne,
  'tr': _notOne,
  'bg': _notOne,
  'ca': _notOne,
  'es': _notOne,
  'it': _notOne,
  'eu': _notOne,
  'gl': _notOne,
  'af': _notOne,
  'sq': _notOne,
  'az': _notOne,
  'kk': _notOne,
  'ky': _notOne,
  'uz': _notOne,
  'ka': _notOne,
  'mn': _notOne,
  'ne': _notOne,
  'ur': _notOne,
  'sw': _notOne,
  'ta': _notOne,
  'te': _notOne,
  'ml': _notOne,
  'mr': _notOne,
  'or': _notOne,
  'eo': _notOne,
  'fy': _notOne,
  'ha': _notOne,
  'ckb': _notOne,
  'lb': _notOne,
  'fo': _notOne,
  'he': _notOne,
  'iw': _notOne,
  'fr': _moreThanOne,
  'pt': _moreThanOne,
  'hi': _moreThanOne,
  'bn': _moreThanOne,
  'gu': _moreThanOne,
  'as': _moreThanOne,
  'pa': _moreThanOne,
  'kn': _moreThanOne,
  'zu': _moreThanOne,
  'am': _moreThanOne,
  'fa': _moreThanOne,
  'hy': _moreThanOne,
  'si': _moreThanOne,
  'ru': _eastSlavic,
  'uk': _eastSlavic,
  'be': _eastSlavic,
  'sr': _eastSlavic,
  'hr': _eastSlavic,
  'bs': _eastSlavic,
  'pl':
      'nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && '
      '(n%100<10 || n%100>=20) ? 1 : 2);',
  'cs': 'nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;',
  'sk': 'nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;',
  'lt':
      'nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && '
      '(n%100<10 || n%100>=20) ? 1 : 2);',
  'lv': 'nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n != 0 ? 1 : 2);',
  'ro':
      'nplurals=3; plural=(n==1 ? 0 : (n==0 || (n%100 > 0 && n%100 < 20)) '
      '? 1 : 2);',
  'sl':
      'nplurals=4; plural=(n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || '
      'n%100==4 ? 2 : 3);',
  'gd':
      'nplurals=4; plural=(n==1 || n==11) ? 0 : (n==2 || n==12) ? 1 : '
      '(n > 2 && n < 20) ? 2 : 3;',
  'ga':
      'nplurals=5; plural=(n==1 ? 0 : n==2 ? 1 : n>2 && n<7 ? 2 : '
      'n>6 && n<11 ? 3 : 4);',
  'ar':
      'nplurals=6; plural=(n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : '
      'n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5);',
  'cy':
      'nplurals=6; plural=(n==0) ? 0 : (n==1) ? 1 : (n==2) ? 2 : '
      '(n==3) ? 3 : (n==6) ? 4 : 5;',
  'is': 'nplurals=2; plural=(n%10!=1 || n%100==11);',
  'mk': 'nplurals=2; plural=(n%10==1 && n%100!=11) ? 0 : 1;',
};

/// The gettext `Plural-Forms` header value for [tag] (Brazilian and
/// European Portuguese differ), or null for a language this table does
/// not know.
String? gettextPluralForms(String? tag) {
  final canonical = canonicalLanguageTag(tag);
  if (canonical == null) return null;
  if (canonical == 'pt-PT') return _notOne;
  return _pluralForms[canonical.split('-').first];
}

/// A parsed `Plural-Forms` value: the number of forms and which form a
/// number uses.
class PluralForms {
  const new(this.count, this._form);

  final int count;
  final int Function(int n) _form;

  /// The form index for [n] (clamped to `0..count-1`).
  int formFor(int n) {
    final form = _form(n);
    return form < 0 || form >= count ? count - 1 : form;
  }

  /// Parses `nplurals=N; plural=EXPRESSION;`; null when it is malformed
  /// (or the template's `nplurals=INTEGER; plural=EXPRESSION;`).
  static PluralForms? parse(String? value) {
    if (value == null) return null;
    final match = RegExp(r'nplurals\s*=\s*(\d+)\s*;\s*plural\s*=\s*([^;]+);?')
        .firstMatch(value);
    if (match == null) return null;
    final count = int.parse(match.group(1)!);
    if (count < 1 || count > 10) return null;
    try {
      final expression = _PluralParser(match.group(2)!).parse();
      return PluralForms(count, expression);
    } on FormatException {
      return null;
    }
  }
}

/// A recursive-descent parser for the C subset of plural expressions.
class _PluralParser {
  new(String source)
    : _tokens = RegExp(r'\d+|n|\|\||&&|==|!=|<=|>=|[-+*/%<>!?:()]')
          .allMatches(source)
          .map((match) => match.group(0)!)
          .toList() {
    final rest = source.replaceAll(
      RegExp(r'\d+|n|\|\||&&|==|!=|<=|>=|[-+*/%<>!?:()\s]'),
      '',
    );
    if (rest.isNotEmpty) throw FormatException('Bad plural expression', source);
  }

  final List<String> _tokens;
  int _pos = 0;

  int Function(int) parse() {
    final expression = _ternary();
    if (_pos != _tokens.length) throw const FormatException('Trailing input');
    return expression;
  }

  String? get _peek => _pos < _tokens.length ? _tokens[_pos] : null;

  void _expect(String token) {
    if (_peek != token) throw FormatException('Expected $token');
    _pos++;
  }

  int Function(int) _ternary() {
    final condition = _binary(0);
    if (_peek != '?') return condition;
    _pos++;
    final then = _ternary();
    _expect(':');
    final otherwise = _ternary();
    return (n) => condition(n) != 0 ? then(n) : otherwise(n);
  }

  static const _levels = [
    ['||'],
    ['&&'],
    ['==', '!='],
    ['<', '>', '<=', '>='],
    ['+', '-'],
    ['*', '/', '%'],
  ];

  int Function(int) _binary(int level) {
    if (level == _levels.length) return _unary();
    var left = _binary(level + 1);
    while (_peek != null && _levels[level].contains(_peek)) {
      final operator = _tokens[_pos++];
      final right = _binary(level + 1);
      final a = left;
      left = (n) => _apply(operator, a(n), right(n));
    }
    return left;
  }

  static int _apply(String operator, int a, int b) => switch (operator) {
    '||' => (a != 0 || b != 0) ? 1 : 0,
    '&&' => (a != 0 && b != 0) ? 1 : 0,
    '==' => a == b ? 1 : 0,
    '!=' => a != b ? 1 : 0,
    '<' => a < b ? 1 : 0,
    '>' => a > b ? 1 : 0,
    '<=' => a <= b ? 1 : 0,
    '>=' => a >= b ? 1 : 0,
    '+' => a + b,
    '-' => a - b,
    '*' => a * b,
    '/' => b == 0 ? 0 : a ~/ b,
    _ => b == 0 ? 0 : a % b,
  };

  int Function(int) _unary() {
    final token = _peek;
    if (token == null) throw const FormatException('Unexpected end');
    _pos++;
    switch (token) {
      case '!':
        final operand = _unary();
        return (n) => operand(n) == 0 ? 1 : 0;
      case '-':
        final operand = _unary();
        return (n) => -operand(n);
      case '(':
        final inner = _ternary();
        _expect(')');
        return inner;
      case 'n':
        return (n) => n;
    }
    final value = int.tryParse(token);
    if (value == null) throw FormatException('Unexpected $token');
    return (_) => value;
  }
}

// ---------------------------------------------------------------------------
// Placeholders
// ---------------------------------------------------------------------------

/// Placeholder patterns of string resources.
///
/// All of them take linear time on hostile text: no two adjacent or nested
/// repetitions can match the same characters (a width never starts with
/// `0`, which is a flag), so the regular expression engine never
/// backtracks over more than one run of characters. [ProtectedPatterns]
/// are only used where they are linear too.
abstract final class LocalisationPatterns {
  static const _flags = "[-+0#']*";
  static const _width = r'(?:[1-9]\d*|\*)?(?:\.(?:\d+|\*))?';
  static const _length = '(?:hh|h|ll|l|L|q|j|z|t)?';
  static const _conversion = '[diouxXeEfFgGaAcspn@]';

  /// printf-style conversions as format strings use them (`%s`, `%1$d`,
  /// `%.2f`, `%lld`, `%@`, `%%`) and Apple substitutions (`%#@files@`,
  /// `%arg`).
  static const printf =
      '%%|%#@[A-Za-z_][A-Za-z0-9_]*@|%arg(?![A-Za-z])'
      '|%(?:\\d+\\\$)?$_flags$_width$_length$_conversion';

  /// [printf] in strings that are not known to be format strings: a
  /// conversion running into a word (`50%off`) is not one, unless it is
  /// positional (`%1$s`) or `%@`.
  static const printfInText =
      '%%|%#@[A-Za-z_][A-Za-z0-9_]*@|%arg(?![A-Za-z])'
      '|%\\d+\\\$$_flags$_width$_length$_conversion'
      '|%$_flags$_width$_length(?:@|[diouxXeEfFgGaAcspn](?![A-Za-z]))';

  /// Python named conversions (`%(name)s`).
  static const pythonNamed =
      r'%\([A-Za-z_]\w*\)[-+0# ]*(?:[1-9]\d*)?(?:\.\d+)?[diouxXeEfFgGcrsa%]';

  /// printf placeholders of JSON and ARB values (like
  /// [ProtectedPatterns.printf]; a width never starts with `0`, which the
  /// `0` flag absorbs, so `%000…` stays linear).
  static const jsonPrintf =
      r'%(?:\d+\$)?(?:\([A-Za-z_]\w*\))?[-+ 0#]*(?:[1-9]\d*)?(?:\.\d+)?[sdifuxXeEgGcp@]';

  /// HTML/XML tags and comments, the same as [ProtectedPatterns.htmlTag]
  /// (both are linear). A comment never contains `<!--`, so that text full
  /// of unclosed `<!--` is not scanned to its end again and again.
  static const htmlTag =
      r'<!--(?:(?!<!--)[\s\S])*?-->|</?[A-Za-z][\w:.-]*(?:\s[^<>]*)?/?>';

  /// Brace placeholders: `{name}`, `{0}`, `{0:.2f}`, `{name!r}`, Java
  /// `{0,number}`.
  static const braces =
      r'\{(?:[A-Za-z_][\w.-]*|\d+)(?:![rsa])?(?:[:,][^{}]*)?\}|\{\}';

  /// Qt and KDE arguments (`%1`, `%L2`).
  static const qt = r'%L?\d{1,2}(?!\d)';

  /// Placeholders of string resources (Android, Apple, xcstrings): format
  /// conversions, braces, templates, URLs, e-mail addresses, and markup or
  /// character references written as text (for `Html.fromHtml` and
  /// attributed strings).
  static final RegExp resource = ProtectedPatterns.combine([
    htmlTag,
    ProtectedPatterns.htmlEntity,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
    braces,
    printf,
  ]);

  /// Free text in resource files whose strings may or may not be format
  /// strings (XLIFF, CSV, HTML text): [printfInText] instead of [printf],
  /// and escaped markup (`&lt;b&gt;` reads as `<b>`).
  static final RegExp text = ProtectedPatterns.combine([
    htmlTag,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
    ProtectedPatterns.braces,
    printfInText,
  ]);

  /// HTML text: URLs, e-mail addresses, escaped markup and template
  /// placeholders (`{{name}}`, `${name}`).
  static final RegExp html = ProtectedPatterns.combine([
    htmlTag,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
  ]);

  /// JSON / ARB string values: [ProtectedPatterns.json] in linear time.
  static final RegExp json = ProtectedPatterns.combine([
    htmlTag,
    ProtectedPatterns.htmlEntity,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
    jsonPrintf,
  ]);

  /// Markdown inline content: [ProtectedPatterns.markdown] in linear time
  /// (image descriptions and footnote labels never contain `[`, so that a
  /// line full of `![` or `[^` is not scanned to its end from each).
  static final RegExp markdown = ProtectedPatterns.combine([
    // Code spans (single or double backticks).
    r'``(?:[^`]|`(?!`))+``|`[^`\n]+`',
    // Images are kept whole (a destination with one pair of parentheses).
    r'!\[[^\[\]\n]*\]\([^()\s]*(?:\([^()]*\)[^()\s]*)?(?:\s+"[^"]*")?\)',
    // Link destinations and reference labels right after `]`.
    r'''(?<=\])\((?:[^()\s]|\([^()]*\))*(?:\s+(?:"[^"]*"|'[^']*'|\([^()]*\)))?\)''',
    r'(?<=\])\[[^\]\n]*\]',
    // Footnote references.
    r'\[\^[^\[\]\n]+\]',
    // Autolinks.
    r'<(?:https?|ftp|mailto):[^<>\s]+>|<[^<>\s@]+@[^<>\s@]+>',
    htmlTag,
    ProtectedPatterns.htmlEntity,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    // Inline math.
    r'\$\$[^$\n]+\$\$',
  ]);
}
