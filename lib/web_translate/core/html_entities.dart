/// HTML character reference decoding (named + numeric), without any HTML
/// parser dependency.
library;

import 'package:mozhi/web_translate/core/charset.dart';

/// Decodes HTML character references in [input].
///
/// * Numeric references (`&#233;`, `&#xE9;`), with or without the trailing
///   semicolon. Invalid code points become U+FFFD and the C1 range
///   (0x80-0x9F) is mapped through windows-1252, like browsers do.
/// * Named references from the HTML 4 set plus common HTML 5 additions.
///   The legacy Latin-1 names (`&amp`, `&copy`, `&eacute`, ...) are also
///   recognised without a semicolon, except inside attribute values when
///   followed by `=` or an alphanumeric character (`?a=1&copy=2`).
/// * Anything else (`AT&T`, `&unknown;`) is left untouched.
String decodeHtmlEntities(String input, {bool inAttribute = false}) {
  var amp = input.indexOf('&');
  if (amp < 0) return input;
  final out = StringBuffer();
  var start = 0;
  final length = input.length;
  while (amp >= 0) {
    out.write(input.substring(start, amp));
    final decoded = _decodeAt(input, amp, inAttribute);
    if (decoded == null) {
      out.write('&');
      start = amp + 1;
    } else {
      out.write(decoded.text);
      start = decoded.end;
    }
    amp = start < length ? input.indexOf('&', start) : -1;
  }
  out.write(input.substring(start));
  return out.toString();
}

/// Named references (without `&`/`;`) -> replacement text.
final Map<String, String> htmlNamedEntities = {
  ..._latin1Entities,
  ..._otherEntities,
  'AMP': '&',
  'LT': '<',
  'GT': '>',
  'QUOT': '"',
  'COPY': '©',
  'REG': '®',
};

({String text, int end})? _decodeAt(String s, int amp, bool inAttribute) {
  final length = s.length;
  var i = amp + 1;
  if (i >= length) return null;
  if (s.codeUnitAt(i) == _hash) {
    i++;
    var hex = false;
    if (i < length && (s.codeUnitAt(i) | 0x20) == _lowerX) {
      hex = true;
      i++;
    }
    final digitsStart = i;
    while (i < length && _isDigit(s.codeUnitAt(i), hex: hex)) {
      i++;
    }
    if (i == digitsStart) return null;
    final digits = s.substring(digitsStart, i);
    if (i < length && s.codeUnitAt(i) == _semicolon) i++;
    final value = digits.length > 8
        ? null
        : int.tryParse(digits, radix: hex ? 16 : 10);
    return (text: _codePointText(value), end: i);
  }

  // Named reference: letters and digits, at most 32 of them.
  final nameStart = i;
  while (i < length && i - nameStart < 32 && _isAlnum(s.codeUnitAt(i))) {
    i++;
  }
  if (i == nameStart) return null;
  if (i < length && s.codeUnitAt(i) == _semicolon) {
    final value = htmlNamedEntities[s.substring(nameStart, i)];
    if (value != null) return (text: value, end: i + 1);
  }
  // Legacy names without a semicolon: longest known prefix wins.
  for (var end = i; end - nameStart >= 2; end--) {
    final name = s.substring(nameStart, end);
    if (!_legacyNames.contains(name)) continue;
    if (inAttribute && end < length) {
      final next = s.codeUnitAt(end);
      if (next == _equals || _isAlnum(next)) return null;
    }
    return (text: htmlNamedEntities[name]!, end: end);
  }
  return null;
}

String _codePointText(int? value) {
  if (value == null ||
      value == 0 ||
      value > 0x10FFFF ||
      (value >= 0xD800 && value <= 0xDFFF)) {
    return '�';
  }
  if (value >= 0x80 && value <= 0x9F) {
    return String.fromCharCode(windows1252HighCodes[value - 0x80]);
  }
  return String.fromCharCode(value);
}

const _hash = 0x23; // #
const _semicolon = 0x3B; // ;
const _equals = 0x3D; // =
const _lowerX = 0x78; // x

bool _isDigit(int c, {required bool hex}) {
  if (c >= 0x30 && c <= 0x39) return true;
  if (!hex) return false;
  final lower = c | 0x20;
  return lower >= 0x61 && lower <= 0x66;
}

bool _isAlnum(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);

/// Names that browsers also accept without a trailing semicolon.
final Set<String> _legacyNames = {
  ..._latin1Names,
  'amp',
  'lt',
  'gt',
  'quot',
  'AMP',
  'LT',
  'GT',
  'QUOT',
  'COPY',
  'REG',
};

/// Names of U+00A0..U+00FF, in code point order.
const _latin1Names = [
  'nbsp', 'iexcl', 'cent', 'pound', 'curren', 'yen', 'brvbar', 'sect', //
  'uml', 'copy', 'ordf', 'laquo', 'not', 'shy', 'reg', 'macr', //
  'deg', 'plusmn', 'sup2', 'sup3', 'acute', 'micro', 'para', 'middot', //
  'cedil', 'sup1', 'ordm', 'raquo', 'frac14', 'frac12', 'frac34', 'iquest', //
  'Agrave', 'Aacute', 'Acirc', 'Atilde', 'Auml', 'Aring', 'AElig', 'Ccedil',
  'Egrave', 'Eacute', 'Ecirc', 'Euml', 'Igrave', 'Iacute', 'Icirc', 'Iuml',
  'ETH', 'Ntilde', 'Ograve', 'Oacute', 'Ocirc', 'Otilde', 'Ouml', 'times',
  'Oslash', 'Ugrave', 'Uacute', 'Ucirc', 'Uuml', 'Yacute', 'THORN', 'szlig',
  'agrave', 'aacute', 'acirc', 'atilde', 'auml', 'aring', 'aelig', 'ccedil',
  'egrave', 'eacute', 'ecirc', 'euml', 'igrave', 'iacute', 'icirc', 'iuml',
  'eth', 'ntilde', 'ograve', 'oacute', 'ocirc', 'otilde', 'ouml', 'divide',
  'oslash', 'ugrave', 'uacute', 'ucirc', 'uuml', 'yacute', 'thorn', 'yuml',
];

final Map<String, String> _latin1Entities = {
  for (var i = 0; i < _latin1Names.length; i++)
    _latin1Names[i]: String.fromCharCode(0xA0 + i),
};

const Map<String, String> _otherEntities = {
  // Markup-significant.
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  // Latin Extended / spacing modifiers.
  'OElig': 'Œ',
  'oelig': 'œ',
  'Scaron': 'Š',
  'scaron': 'š',
  'Yuml': 'Ÿ',
  'fnof': 'ƒ',
  'circ': 'ˆ',
  'tilde': '˜',
  // Greek.
  'Alpha': 'Α',
  'Beta': 'Β',
  'Gamma': 'Γ',
  'Delta': 'Δ',
  'Epsilon': 'Ε',
  'Zeta': 'Ζ',
  'Eta': 'Η',
  'Theta': 'Θ',
  'Iota': 'Ι',
  'Kappa': 'Κ',
  'Lambda': 'Λ',
  'Mu': 'Μ',
  'Nu': 'Ν',
  'Xi': 'Ξ',
  'Omicron': 'Ο',
  'Pi': 'Π',
  'Rho': 'Ρ',
  'Sigma': 'Σ',
  'Tau': 'Τ',
  'Upsilon': 'Υ',
  'Phi': 'Φ',
  'Chi': 'Χ',
  'Psi': 'Ψ',
  'Omega': 'Ω',
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'epsilon': 'ε',
  'zeta': 'ζ',
  'eta': 'η',
  'theta': 'θ',
  'iota': 'ι',
  'kappa': 'κ',
  'lambda': 'λ',
  'mu': 'μ',
  'nu': 'ν',
  'xi': 'ξ',
  'omicron': 'ο',
  'pi': 'π',
  'rho': 'ρ',
  'sigmaf': 'ς',
  'sigma': 'σ',
  'tau': 'τ',
  'upsilon': 'υ',
  'phi': 'φ',
  'chi': 'χ',
  'psi': 'ψ',
  'omega': 'ω',
  'thetasym': 'ϑ',
  'upsih': 'ϒ',
  'piv': 'ϖ',
  // General punctuation and spaces.
  'ensp': ' ',
  'emsp': ' ',
  'thinsp': ' ',
  'zwnj': '‌',
  'zwj': '‍',
  'lrm': '‎',
  'rlm': '‏',
  'ndash': '–',
  'mdash': '—',
  'horbar': '―',
  'lsquo': '‘',
  'rsquo': '’',
  'sbquo': '‚',
  'ldquo': '“',
  'rdquo': '”',
  'bdquo': '„',
  'dagger': '†',
  'Dagger': '‡',
  'bull': '•',
  'hellip': '…',
  'permil': '‰',
  'prime': '′',
  'Prime': '″',
  'lsaquo': '‹',
  'rsaquo': '›',
  'oline': '‾',
  'frasl': '⁄',
  'euro': '€',
  'image': 'ℑ',
  'weierp': '℘',
  'real': 'ℜ',
  'trade': '™',
  'alefsym': 'ℵ',
  // Arrows.
  'larr': '←',
  'uarr': '↑',
  'rarr': '→',
  'darr': '↓',
  'harr': '↔',
  'crarr': '↵',
  'lArr': '⇐',
  'uArr': '⇑',
  'rArr': '⇒',
  'dArr': '⇓',
  'hArr': '⇔',
  // Mathematical operators.
  'forall': '∀',
  'part': '∂',
  'exist': '∃',
  'empty': '∅',
  'nabla': '∇',
  'isin': '∈',
  'notin': '∉',
  'ni': '∋',
  'prod': '∏',
  'sum': '∑',
  'minus': '−',
  'lowast': '∗',
  'radic': '√',
  'prop': '∝',
  'infin': '∞',
  'ang': '∠',
  'and': '∧',
  'or': '∨',
  'cap': '∩',
  'cup': '∪',
  'int': '∫',
  'there4': '∴',
  'sim': '∼',
  'cong': '≅',
  'asymp': '≈',
  'ne': '≠',
  'equiv': '≡',
  'le': '≤',
  'ge': '≥',
  'sub': '⊂',
  'sup': '⊃',
  'nsub': '⊄',
  'sube': '⊆',
  'supe': '⊇',
  'oplus': '⊕',
  'otimes': '⊗',
  'perp': '⊥',
  'sdot': '⋅',
  'lceil': '⌈',
  'rceil': '⌉',
  'lfloor': '⌊',
  'rfloor': '⌋',
  'lang': '⟨',
  'rang': '⟩',
  'loz': '◊',
  'spades': '♠',
  'clubs': '♣',
  'hearts': '♥',
  'diams': '♦',
  // Common HTML 5 additions.
  'Tab': '\t',
  'NewLine': '\n',
  'excl': '!',
  'num': '#',
  'dollar': r'$',
  'percnt': '%',
  'lpar': '(',
  'rpar': ')',
  'ast': '*',
  'plus': '+',
  'comma': ',',
  'period': '.',
  'sol': '/',
  'colon': ':',
  'semi': ';',
  'equals': '=',
  'quest': '?',
  'commat': '@',
  'lsqb': '[',
  'bsol': r'\',
  'rsqb': ']',
  'Hat': '^',
  'lowbar': '_',
  'grave': '`',
  'lcub': '{',
  'verbar': '|',
  'vert': '|',
  'rcub': '}',
  'hyphen': '‐',
  'dash': '‐',
  'nbhy': '‑',
  'ZeroWidthSpace': '​',
  'NoBreak': '⁠',
  'check': '✓',
  'cross': '✗',
  'star': '☆',
  'starf': '★',
  'phone': '☎',
  'female': '♀',
  'male': '♂',
  'sharp': '♯',
  'flat': '♭',
  'natural': '♮',
  'copysr': '℗',
  'numero': '№',
  'half': '½',
  'centerdot': '·',
  'angle': '∠',
  'larrhk': '↩',
  'rarrhk': '↪',
};
