import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/fsrs.dart';

/// How a word of the expected answer came out.
enum AnswerWordStatus {
  /// Said or typed as expected (ignoring case, punctuation and accents).
  matched,

  /// Nearly: a letter or two off, or part of it.
  close,

  /// Not said or typed.
  missed,
}

/// A word of the expected answer, as written there, and how it came out.
final class AnswerWord extends Equatable {
  const new(this.text, this.status);

  final String text;
  final AnswerWordStatus status;

  @override
  List<Object?> get props => [text, status];
}

/// The comparison of an answer (heard or typed) with the expected text:
/// each expected word [matched], [AnswerWordStatus.close] or missed, and
/// the answer's words that were not expected ([extra]).
final class AnswerCheck extends Equatable {
  const new({
    required this.answer,
    required this.words,
    this.extra = const [],
    this.score = 1,
  });

  /// What was heard or typed.
  final String answer;

  /// The expected text word by word (character by character in Chinese,
  /// Japanese and Thai), with how each came out.
  final List<AnswerWord> words;

  /// Words of the answer that the expected text does not have.
  final List<String> extra;

  /// 0 (nothing right) to 1 (all right, nothing else).
  final double score;

  /// How many expected words came out right.
  int get matched =>
      words.where((word) => word.status == AnswerWordStatus.matched).length;

  /// Whether the answer was right, word for word.
  bool get isExact =>
      extra.isEmpty &&
      words.every((word) => word.status == AnswerWordStatus.matched);

  /// The rating the comparison suggests (the user rates): Good when it was
  /// right, Hard when most of it was, Again otherwise. Never Easy: only
  /// the user knows how easy it was.
  FsrsRating get suggestedRating => isExact || score >= 0.999
      ? FsrsRating.good
      : score >= 0.75
      ? FsrsRating.hard
      : FsrsRating.again;

  @override
  List<Object?> get props => [answer, words, extra, score];
}

/// Compares [answer] with [expected] in [languageCode] (a BCP-47 code,
/// for number words): both are normalised ([answerKeys]: case,
/// punctuation, accents, single and compound number words as digits), then
/// aligned word by word (the longest common subsequence, where words a letter
/// or two apart count as close).
AnswerCheck checkAnswer({
  required String expected,
  required String answer,
  String? languageCode,
}) {
  final expectedTokens = _tokenize(expected, languageCode: languageCode);
  final heardTokens = _tokenize(answer, languageCode: languageCode);
  final shown = expectedTokens.shown;
  final keys = expectedTokens.keys;
  final owners = expectedTokens.owners;
  final heard = heardTokens.keys;
  final heardShown = heardTokens.shown;
  final heardOwners = heardTokens.owners;

  final alignment = _align(
    keys.take(_maxTokens).toList(),
    heard.take(_maxTokens).toList(),
  );
  // Words past [_maxTokens] are not compared: missed.
  final statuses = [
    ...alignment.expected,
    for (var i = alignment.expected.length; i < keys.length; i++)
      AnswerWordStatus.missed,
  ];
  final words = <AnswerWord>[];
  for (var i = 0; i < shown.length; i++) {
    final own = [
      for (var k = 0; k < keys.length; k++)
        if (owners[k].contains(i)) statuses[k],
    ];
    // Punctuation alone (a dash, an emoji) is never wrong.
    if (own.isEmpty) continue;
    final status = own.every((s) => s == AnswerWordStatus.matched)
        ? AnswerWordStatus.matched
        : own.every((s) => s == AnswerWordStatus.missed)
        ? AnswerWordStatus.missed
        : AnswerWordStatus.close;
    words.add(AnswerWord(shown[i], status));
  }
  final extraOwners = <int>{
    for (var k = 0; k < heard.length; k++)
      if (k >= alignment.heard.length || !alignment.heard[k]) ...heardOwners[k],
  };
  final extra = [for (final i in extraOwners.toList()..sort()) heardShown[i]];
  final weight = statuses.fold<double>(
    0,
    (sum, status) =>
        sum +
        switch (status) {
          AnswerWordStatus.matched => 1,
          AnswerWordStatus.close => 0.5,
          AnswerWordStatus.missed => 0,
        },
  );
  final total = math.max(keys.length, heard.length);
  return AnswerCheck(
    answer: answer,
    words: List.unmodifiable(words),
    extra: List.unmodifiable(extra),
    score: total == 0 ? 1 : weight / total,
  );
}

/// The normalised words of [text]: lower case, without punctuation,
/// symbols or accents (apostrophes join, other punctuation separates),
/// single and compound number words of [languageCode] as digits; Chinese and
/// Japanese characters and Thai, Lao, Khmer and Burmese letters one by one.
List<String> answerKeys(String text, {String? languageCode}) =>
    _tokenize(text, languageCode: languageCode).keys;

/// The most words compared (longer texts compare their beginning).
const _maxTokens = 300;

/// Tokenizes [text] into display tokens, normalized keys (with compound
/// numbers collapsed for supported languages), and the display-token indices
/// owning each key.
({List<String> shown, List<String> keys, List<List<int>> owners}) _tokenize(
  String text, {
  String? languageCode,
}) {
  final shown = _displayTokens(text);
  final raw = _extractRawTokens(shown);
  final lang = _primaryLanguage(languageCode);
  if (lang == null) {
    return (
      shown: shown,
      keys: [for (final token in raw) token.text],
      owners: [
        for (final token in raw) [token.owner],
      ],
    );
  }
  final expanded = _expandFusedNumbers(raw, lang);
  final keys = <String>[];
  final owners = <List<int>>[];
  var i = 0;
  while (i < expanded.length) {
    final parsed = _parseNumber(expanded, i, lang);
    if (parsed != null) {
      keys.add(parsed.value.toString());
      final seen = <int>{};
      owners.add([
        for (var j = i; j < parsed.end; j++)
          if (seen.add(expanded[j].owner)) expanded[j].owner,
      ]);
      i = parsed.end;
    } else {
      keys.add(expanded[i].text);
      owners.add([expanded[i].owner]);
      i++;
    }
  }
  return (shown: shown, keys: keys, owners: owners);
}

/// [text] as shown: its words (split at white space) and, in scripts
/// written without spaces, single characters.
List<String> _displayTokens(String text) {
  final tokens = <String>[];
  for (final word in text.trim().split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final buffer = StringBuffer();
    for (final rune in word.runes) {
      if (_isUnspaced(rune)) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        tokens.add(String.fromCharCode(rune));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
  }
  return tokens;
}

final class _RawToken {
  const new(
    this.text,
    this.owner, {
    required this.breakBefore,
    required this.breakAfter,
  });

  final String text;
  final int owner;
  final bool breakBefore;
  final bool breakAfter;
}

final _apostrophes = RegExp("['’ʼ‘`´]");
final _wordRun = RegExp(r'[^\p{P}\p{S}\s]+', unicode: true);

/// Whether [separator] contains anything stronger than a hyphen (e.g. a comma,
/// period, slash, or parenthesis) that should stop compound number joining.
bool _hasHardSeparator(String separator) {
  for (final rune in separator.runes) {
    if (rune != 0x002d && rune != 0x2010 && rune != 0x2011) {
      return true;
    }
  }
  return false;
}

/// Extracts folded raw tokens from [shown], tracking display-token ownership
/// and non-hyphen punctuation boundaries.
List<_RawToken> _extractRawTokens(List<String> shown) {
  final result = <_RawToken>[];
  var barrier = false;
  for (var i = 0; i < shown.length; i++) {
    final folded = _fold(shown[i].toLowerCase()).replaceAll(_apostrophes, '');
    final matches = _wordRun.allMatches(folded).toList();
    if (matches.isEmpty) {
      barrier = true;
      continue;
    }
    for (var j = 0; j < matches.length; j++) {
      final match = matches[j];
      final leading = j == 0
          ? folded.substring(0, match.start)
          : folded.substring(matches[j - 1].end, match.start);
      final trailing = j == matches.length - 1
          ? folded.substring(match.end)
          : folded.substring(match.end, matches[j + 1].start);
      result.add(
        _RawToken(
          match.group(0)!,
          i,
          breakBefore: (j == 0 && barrier) || _hasHardSeparator(leading),
          breakAfter: _hasHardSeparator(trailing),
        ),
      );
    }
    barrier = false;
  }
  return result;
}

/// Folds the letters with diacritics of lower-case [text] (and drops
/// combining marks, Arabic vowel marks and Hebrew points).
String _fold(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (_isMark(rune)) continue;
    if (_extraFolds[rune] case final plain?) {
      buffer.write(plain);
      continue;
    }
    if (rune <= 0xffff) {
      final index = _accented.indexOf(String.fromCharCode(rune));
      if (index >= 0) {
        buffer.write(_plain[index]);
        continue;
      }
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

bool _isMark(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0x0591 && rune <= 0x05bd) ||
    rune == 0x05bf ||
    rune == 0x05c1 ||
    rune == 0x05c2 ||
    rune == 0x05c4 ||
    rune == 0x05c5 ||
    rune == 0x05c7 ||
    (rune >= 0x064b && rune <= 0x065f) ||
    rune == 0x0670;

/// Letters without a decomposition that read as plain ones.
const _extraFolds = {
  0x00df: 'ss', // ß
  0x00e6: 'ae', // æ
  0x0153: 'oe', // œ
  0x00f8: 'o', // ø
  0x0111: 'd', // đ
  0x0142: 'l', // ł
  0x0127: 'h', // ħ
  0x0131: 'i', // dotless ı
  0x03c2: 'σ', // final ς
};

/// Scripts written without spaces between words: compared character by
/// character.
bool _isUnspaced(int rune) =>
    (rune >= 0x0e00 && rune <= 0x0eff) || // Thai, Lao
    (rune >= 0x1000 && rune <= 0x109f) || // Myanmar
    (rune >= 0x1780 && rune <= 0x17ff) || // Khmer
    (rune >= 0x3040 && rune <= 0x30ff) || // kana
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x2fa1f);

// Compound number parsing ----------------------------------------------------

const _supportedNumberLanguages = {'en', 'es', 'fr', 'de', 'it', 'pt', 'nl'};

String? _primaryLanguage(String? code) {
  final primary = code?.split(RegExp('[-_]')).first.toLowerCase();
  return _supportedNumberLanguages.contains(primary) ? primary : null;
}

bool _canJoin(List<_RawToken> tokens, int prev, int next) =>
    !tokens[prev].breakAfter && !tokens[next].breakBefore;

/// Expands single-word fused compound numbers in German, Dutch and Italian
/// into their constituent number morphemes (preserving display-token ownership
/// and punctuation boundaries), leaving all other words untouched.
List<_RawToken> _expandFusedNumbers(List<_RawToken> raw, String lang) {
  if (lang != 'de' && lang != 'nl' && lang != 'it') return raw;
  final out = <_RawToken>[];
  for (final token in raw) {
    final parts = switch (lang) {
      'de' => _splitFusedWord(
        token.text,
        baseWords: _deBaseWords,
        morphemes: _deMorphemes,
        lang: 'de',
      ),
      'nl' => _splitFusedWord(
        token.text,
        baseWords: _nlBaseWords,
        morphemes: _nlMorphemes,
        lang: 'nl',
      ),
      'it' => _splitItalianFusedWord(token.text),
      _ => null,
    };
    if (parts == null) {
      out.add(token);
      continue;
    }
    for (var i = 0; i < parts.length; i++) {
      out.add(
        _RawToken(
          parts[i],
          token.owner,
          breakBefore: i == 0 && token.breakBefore,
          breakAfter: i == parts.length - 1 && token.breakAfter,
        ),
      );
    }
  }
  return out;
}

/// Splits a German or Dutch fused number word into morphemes, accepting the
/// split only if the entire word consumes into a single valid number.
List<String>? _splitFusedWord(
  String word, {
  required Set<String> baseWords,
  required List<String> morphemes,
  required String lang,
}) {
  if (word.length < 5 || baseWords.contains(word)) return null;
  final parts = <String>[];
  bool dfs(int offset) {
    if (offset == word.length) return parts.length >= 2;
    for (final m in morphemes) {
      if (word.startsWith(m, offset)) {
        parts.add(m);
        if (dfs(offset + m.length)) return true;
        parts.removeLast();
      }
    }
    return false;
  }

  if (!dfs(0)) return null;
  final synthetic = [
    for (final p in parts)
      _RawToken(p, 0, breakBefore: false, breakAfter: false),
  ];
  final parsed = _parseNumber(synthetic, 0, lang);
  if (parsed == null || parsed.end != parts.length) return null;
  return parts;
}

/// Splits an Italian fused number word (handling vowel elision like `ventuno`,
/// `ventotto`, `centottanta`, `trecentocinque`, `duemilaventisei`).
List<String>? _splitItalianFusedWord(String word) {
  if (word.length < 5 || _itBaseWords.contains(word)) return null;
  final parts = <String>[];
  bool dfs(int offset) {
    if (offset == word.length) return parts.length >= 2;
    for (final entry in _itElidedMorphemes) {
      if (word.startsWith(entry.prefix, offset)) {
        final next = offset + entry.prefix.length;
        if (entry.followedBy.any((suffix) => word.startsWith(suffix, next))) {
          parts.add(entry.canonical);
          if (dfs(next)) return true;
          parts.removeLast();
        }
      }
    }
    for (final m in _itMorphemes) {
      if (word.startsWith(m, offset)) {
        parts.add(m);
        if (dfs(offset + m.length)) return true;
        parts.removeLast();
      }
    }
    return false;
  }

  if (!dfs(0)) return null;
  final synthetic = [
    for (final p in parts)
      _RawToken(p, 0, breakBefore: false, breakAfter: false),
  ];
  final parsed = _parseNumber(synthetic, 0, 'it');
  if (parsed == null || parsed.end != parts.length) return null;
  return parts;
}

/// Parses a single or multi-word number starting at [start] in [tokens] for
/// [lang], returning its integer value and exclusive end index, or null.
({int value, int end})? _parseNumber(
  List<_RawToken> tokens,
  int start,
  String lang,
) {
  if (start >= tokens.length) return null;
  final first = tokens[start].text;
  if (_zeroWords[lang] == first) {
    return (value: 0, end: start + 1);
  }

  var pos = start;
  var total = 0;
  var hasValue = false;

  // Optional millions group (e.g. "two million", "un millon").
  final million = _parseScaleGroup(
    tokens,
    pos,
    lang,
    scale: 1000000,
    scaleWords: _millionWords[lang]!,
    allowImplicitOne: false,
  );
  if (million != null) {
    total += million.value;
    pos = million.end;
    hasValue = true;
  }

  // Optional thousands group (e.g. "two thousand", "mil", "duemila").
  if (!hasValue || (pos < tokens.length && _canJoin(tokens, pos - 1, pos))) {
    final before = pos;
    final afterConn = hasValue ? _skipScaleConnector(tokens, pos, lang) : pos;
    final thousand = _parseScaleGroup(
      tokens,
      afterConn,
      lang,
      scale: 1000,
      scaleWords: _thousandWords[lang]!,
      allowImplicitOne: true,
      implicitOneWords: _implicitThousandWords[lang]!,
    );
    if (thousand != null) {
      total += thousand.value;
      pos = thousand.end;
      hasValue = true;
    } else {
      pos = before;
    }
  }

  // Optional sub-thousand remainder (1..999, or 1100..1999 when no thousands).
  if (!hasValue || (pos < tokens.length && _canJoin(tokens, pos - 1, pos))) {
    final before = pos;
    final afterConn = hasValue ? _skipScaleConnector(tokens, pos, lang) : pos;
    final sub = _parseSubThousand(
      tokens,
      afterConn,
      lang,
      allowTeenHundreds: !hasValue,
    );
    if (sub != null) {
      total += sub.value;
      pos = sub.end;
      hasValue = true;
    } else {
      pos = before;
    }
  }

  return hasValue ? (value: total, end: pos) : null;
}

/// Skips an optional connector (`and` in EN, `e` in PT, `und` in DE, `en` in
/// NL) after a higher scale group when followed by a joinable token.
int _skipScaleConnector(List<_RawToken> tokens, int pos, String lang) {
  final conn = _scaleConnectors[lang];
  if (conn == null || pos + 1 >= tokens.length) return pos;
  if (tokens[pos].text == conn && _canJoin(tokens, pos, pos + 1)) {
    return pos + 1;
  }
  return pos;
}

/// Parses `[multiplier] <scaleWord>` (e.g. `two thousand`, `one hundred twenty
/// thousand`, or standalone `thousand`/`mil`/`mille`).
({int value, int end})? _parseScaleGroup(
  List<_RawToken> tokens,
  int start,
  String lang, {
  required int scale,
  required Set<String> scaleWords,
  required bool allowImplicitOne,
  Set<String> implicitOneWords = const {},
}) {
  if (start >= tokens.length) return null;
  if (allowImplicitOne && implicitOneWords.contains(tokens[start].text)) {
    return (value: scale, end: start + 1);
  }
  final mult = _parseSubThousand(tokens, start, lang, allowTeenHundreds: false);
  if (mult == null) return null;
  final next = mult.end;
  if (next < tokens.length &&
      _canJoin(tokens, next - 1, next) &&
      scaleWords.contains(tokens[next].text)) {
    return (value: mult.value * scale, end: next + 1);
  }
  return null;
}

/// Parses 1..999 (or 1100..1999 when [allowTeenHundreds] is true and a teen
/// multiplies `hundred`/`cent`/`hundert`/`honderd`).
({int value, int end})? _parseSubThousand(
  List<_RawToken> tokens,
  int start,
  String lang, {
  required bool allowTeenHundreds,
}) {
  if (start >= tokens.length) return null;
  final hundreds = _parseHundreds(
    tokens,
    start,
    lang,
    allowTeenMultiplier: allowTeenHundreds,
  );
  if (hundreds != null) {
    final pos = hundreds.end;
    if (pos < tokens.length && _canJoin(tokens, pos - 1, pos)) {
      final afterConn = _skipScaleConnector(tokens, pos, lang);
      final tail = _parseSubHundred(tokens, afterConn, lang);
      // Do not steal the leading multiplier of an immediately following
      // hundreds expression (e.g. "one hundred two hundred" -> 100, 200).
      if (tail != null && !_isFollowedByHundred(tokens, tail.end, lang)) {
        return (value: hundreds.value + tail.value, end: tail.end);
      }
    }
    return hundreds;
  }
  return _parseSubHundred(tokens, start, lang);
}

bool _isFollowedByHundred(List<_RawToken> tokens, int pos, String lang) =>
    pos < tokens.length &&
    _canJoin(tokens, pos - 1, pos) &&
    _hundredWords[lang]!.contains(tokens[pos].text);

/// Parses a hundreds term: fused (`doscientos`, `duzentos`, `cien`, `ciento`,
/// `cem`, `cento`), `[multiplier] <hundredWord>`, or standalone hundred.
({int value, int end})? _parseHundreds(
  List<_RawToken> tokens,
  int start,
  String lang, {
  required bool allowTeenMultiplier,
}) {
  final word = tokens[start].text;
  final fused = _fusedHundreds[lang]?[word];
  if (fused != null) {
    return (value: fused, end: start + 1);
  }
  final hWords = _hundredWords[lang]!;
  if (hWords.contains(word)) {
    return (value: 100, end: start + 1);
  }
  final mult = _parseSubHundred(tokens, start, lang);
  if (mult == null) return null;
  final validMult =
      (mult.value >= 1 && mult.value <= 9) ||
      (allowTeenMultiplier && mult.value >= 11 && mult.value <= 19);
  if (!validMult) return null;
  final next = mult.end;
  if (next < tokens.length &&
      _canJoin(tokens, next - 1, next) &&
      hWords.contains(tokens[next].text)) {
    return (value: mult.value * 100, end: next + 1);
  }
  return null;
}

/// Parses 1..99 according to [lang]'s grammar.
({int value, int end})? _parseSubHundred(
  List<_RawToken> tokens,
  int start,
  String lang,
) => switch (lang) {
  'en' => _parseSubHundredTenUnit(
    tokens,
    start,
    units: _enUnits,
    teens: _enTeens,
    tens: _enTens,
  ),
  'es' => _parseSubHundredEs(tokens, start),
  'pt' => _parseSubHundredTenUnit(
    tokens,
    start,
    units: _ptUnits,
    teens: _ptTeens,
    tens: _ptTens,
    connector: 'e',
    requireConnector: true,
  ),
  'it' => _parseSubHundredTenUnit(
    tokens,
    start,
    units: _itUnits,
    teens: _itTeens,
    tens: _itTens,
  ),
  'fr' => _parseSubHundredFr(tokens, start),
  'de' => _parseSubHundredUnitTen(
    tokens,
    start,
    units: _deUnits,
    teens: _deTeens,
    tens: _deTens,
    connector: 'und',
  ),
  'nl' => _parseSubHundredUnitTen(
    tokens,
    start,
    units: _nlUnits,
    teens: _nlTeens,
    tens: _nlTens,
    connector: 'en',
  ),
  _ => null,
};

({int value, int end})? _parseSubHundredTenUnit(
  List<_RawToken> tokens,
  int start, {
  required Map<String, int> units,
  required Map<String, int> teens,
  required Map<String, int> tens,
  String? connector,
  bool requireConnector = false,
}) {
  if (start >= tokens.length) return null;
  final word = tokens[start].text;
  if (tens[word] case final ten?) {
    final next = start + 1;
    if (next < tokens.length && _canJoin(tokens, start, next)) {
      if (connector != null &&
          tokens[next].text == connector &&
          next + 1 < tokens.length &&
          _canJoin(tokens, next, next + 1)) {
        if (units[tokens[next + 1].text] case final unit?) {
          return (value: ten + unit, end: next + 2);
        }
      } else if (!requireConnector) {
        if (units[tokens[next].text] case final unit?) {
          return (value: ten + unit, end: next + 1);
        }
      }
    }
    return (value: ten, end: next);
  }
  if (teens[word] case final teen?) return (value: teen, end: start + 1);
  if (units[word] case final unit?) return (value: unit, end: start + 1);
  return null;
}

({int value, int end})? _parseSubHundredEs(List<_RawToken> tokens, int start) {
  if (start >= tokens.length) return null;
  final word = tokens[start].text;
  if (_esTwenties[word] case final twenty?) {
    return (value: twenty, end: start + 1);
  }
  return _parseSubHundredTenUnit(
    tokens,
    start,
    units: _esUnits,
    teens: _esTeens,
    tens: _esTens,
    connector: 'y',
    requireConnector: true,
  );
}

({int value, int end})? _parseSubHundredUnitTen(
  List<_RawToken> tokens,
  int start, {
  required Map<String, int> units,
  required Map<String, int> teens,
  required Map<String, int> tens,
  required String connector,
}) {
  if (start >= tokens.length) return null;
  final word = tokens[start].text;
  if (units[word] case final unit?) {
    if (start + 2 < tokens.length &&
        _canJoin(tokens, start, start + 1) &&
        tokens[start + 1].text == connector &&
        _canJoin(tokens, start + 1, start + 2)) {
      if (tens[tokens[start + 2].text] case final ten?) {
        return (value: ten + unit, end: start + 3);
      }
    }
    return (value: unit, end: start + 1);
  }
  if (tens[word] case final ten?) return (value: ten, end: start + 1);
  if (teens[word] case final teen?) return (value: teen, end: start + 1);
  return null;
}

({int value, int end})? _parseSubHundredFr(List<_RawToken> tokens, int start) {
  if (start >= tokens.length) return null;
  final word = tokens[start].text;

  // 80..99: quatre-vingt(s) [1..19]
  if (word == 'quatre' &&
      start + 1 < tokens.length &&
      _canJoin(tokens, start, start + 1) &&
      (tokens[start + 1].text == 'vingt' ||
          tokens[start + 1].text == 'vingts')) {
    final end = start + 2;
    if (end < tokens.length && _canJoin(tokens, end - 1, end)) {
      final tail = _parseFrOneToNineteen(tokens, end);
      if (tail != null) {
        return (value: 80 + tail.value, end: tail.end);
      }
    }
    return (value: 80, end: end);
  }

  // 60..79: soixante [et un/une/onze | 1..19]
  if (word == 'soixante') {
    final next = start + 1;
    if (next < tokens.length && _canJoin(tokens, start, next)) {
      if (tokens[next].text == 'et' &&
          next + 1 < tokens.length &&
          _canJoin(tokens, next, next + 1)) {
        final after = tokens[next + 1].text;
        if (after == 'un' || after == 'une') return (value: 61, end: next + 2);
        if (after == 'onze') return (value: 71, end: next + 2);
      }
      final tail = _parseFrOneToNineteen(tokens, next);
      if (tail != null) {
        return (value: 60 + tail.value, end: tail.end);
      }
    }
    return (value: 60, end: next);
  }

  // 20..59 and Belgian/Swiss 70/80/90.
  if (_frTens[word] case final ten?) {
    final next = start + 1;
    if (next < tokens.length && _canJoin(tokens, start, next)) {
      if (tokens[next].text == 'et' &&
          next + 1 < tokens.length &&
          _canJoin(tokens, next, next + 1) &&
          (tokens[next + 1].text == 'un' || tokens[next + 1].text == 'une')) {
        return (value: ten + 1, end: next + 2);
      }
      if (_frUnits[tokens[next].text] case final unit?) {
        return (value: ten + unit, end: next + 1);
      }
    }
    return (value: ten, end: next);
  }

  return _parseFrOneToNineteen(tokens, start);
}

({int value, int end})? _parseFrOneToNineteen(
  List<_RawToken> tokens,
  int start,
) {
  if (start >= tokens.length) return null;
  final word = tokens[start].text;
  if (word == 'dix') {
    final next = start + 1;
    if (next < tokens.length && _canJoin(tokens, start, next)) {
      final after = tokens[next].text;
      if (after == 'sept') return (value: 17, end: next + 1);
      if (after == 'huit') return (value: 18, end: next + 1);
      if (after == 'neuf') return (value: 19, end: next + 1);
    }
    return (value: 10, end: next);
  }
  if (_frTeens[word] case final teen?) return (value: teen, end: start + 1);
  if (_frUnits[word] case final unit?) return (value: unit, end: start + 1);
  return null;
}

// Language lexicons (folded: no accents, ß as ss) ----------------------------

const _zeroWords = {
  'en': 'zero',
  'es': 'cero',
  'fr': 'zero',
  'de': 'null',
  'it': 'zero',
  'pt': 'zero',
  'nl': 'nul',
};

const _scaleConnectors = {'en': 'and', 'pt': 'e', 'de': 'und', 'nl': 'en'};

const _hundredWords = {
  'en': {'hundred'},
  'es': <String>{},
  'fr': {'cent', 'cents'},
  'de': {'hundert'},
  'it': {'cento'},
  'pt': <String>{},
  'nl': {'honderd'},
};

const _fusedHundreds = {
  'es': {
    'cien': 100,
    'ciento': 100,
    'doscientos': 200,
    'doscientas': 200,
    'trescientos': 300,
    'trescientas': 300,
    'cuatrocientos': 400,
    'cuatrocientas': 400,
    'quinientos': 500,
    'quinientas': 500,
    'seiscientos': 600,
    'seiscientas': 600,
    'setecientos': 700,
    'setecientas': 700,
    'ochocientos': 800,
    'ochocientas': 800,
    'novecientos': 900,
    'novecientas': 900,
  },
  'pt': {
    'cem': 100,
    'cento': 100,
    'duzentos': 200,
    'duzentas': 200,
    'trezentos': 300,
    'trezentas': 300,
    'quatrocentos': 400,
    'quatrocentas': 400,
    'quinhentos': 500,
    'quinhentas': 500,
    'seiscentos': 600,
    'seiscentas': 600,
    'setecentos': 700,
    'setecentas': 700,
    'oitocentos': 800,
    'oitocentas': 800,
    'novecentos': 900,
    'novecentas': 900,
  },
};

const _thousandWords = {
  'en': {'thousand'},
  'es': {'mil'},
  'fr': {'mille'},
  'de': {'tausend'},
  'it': {'mila'},
  'pt': {'mil'},
  'nl': {'duizend'},
};

const _implicitThousandWords = {
  'en': {'thousand'},
  'es': {'mil'},
  'fr': {'mille'},
  'de': {'tausend'},
  'it': {'mille'},
  'pt': {'mil'},
  'nl': {'duizend'},
};

const _millionWords = {
  'en': {'million'},
  'es': {'millon', 'millones'},
  'fr': {'million', 'millions'},
  'de': {'million', 'millionen'},
  'it': {'milione', 'milioni'},
  'pt': {'milhao', 'milhoes'},
  'nl': {'miljoen'},
};

const _enUnits = {
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
};
const _enTeens = {
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
};
const _enTens = {
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

const _esUnits = {
  'uno': 1,
  'una': 1,
  'un': 1,
  'dos': 2,
  'tres': 3,
  'cuatro': 4,
  'cinco': 5,
  'seis': 6,
  'siete': 7,
  'ocho': 8,
  'nueve': 9,
};
const _esTeens = {
  'diez': 10,
  'once': 11,
  'doce': 12,
  'trece': 13,
  'catorce': 14,
  'quince': 15,
  'dieciseis': 16,
  'diecisiete': 17,
  'dieciocho': 18,
  'diecinueve': 19,
};
const _esTwenties = {
  'veinte': 20,
  'veintiuno': 21,
  'veintiun': 21,
  'veintiuna': 21,
  'veintidos': 22,
  'veintitres': 23,
  'veinticuatro': 24,
  'veinticinco': 25,
  'veintiseis': 26,
  'veintisiete': 27,
  'veintiocho': 28,
  'veintinueve': 29,
};
const _esTens = {
  'treinta': 30,
  'cuarenta': 40,
  'cincuenta': 50,
  'sesenta': 60,
  'setenta': 70,
  'ochenta': 80,
  'noventa': 90,
};

const _frUnits = {
  'un': 1,
  'une': 1,
  'deux': 2,
  'trois': 3,
  'quatre': 4,
  'cinq': 5,
  'six': 6,
  'sept': 7,
  'huit': 8,
  'neuf': 9,
};
const _frTeens = {
  'onze': 11,
  'douze': 12,
  'treize': 13,
  'quatorze': 14,
  'quinze': 15,
  'seize': 16,
};
const _frTens = {
  'vingt': 20,
  'trente': 30,
  'quarante': 40,
  'cinquante': 50,
  'septante': 70,
  'huitante': 80,
  'octante': 80,
  'nonante': 90,
};

const _deUnits = {
  'eins': 1,
  'ein': 1,
  'eine': 1,
  'zwei': 2,
  'drei': 3,
  'vier': 4,
  'funf': 5,
  'sechs': 6,
  'sieben': 7,
  'acht': 8,
  'neun': 9,
};
const _deTeens = {
  'zehn': 10,
  'elf': 11,
  'zwolf': 12,
  'dreizehn': 13,
  'vierzehn': 14,
  'funfzehn': 15,
  'sechzehn': 16,
  'siebzehn': 17,
  'achtzehn': 18,
  'neunzehn': 19,
};
const _deTens = {
  'zwanzig': 20,
  'dreissig': 30,
  'vierzig': 40,
  'funfzig': 50,
  'sechzig': 60,
  'siebzig': 70,
  'achtzig': 80,
  'neunzig': 90,
};
const _deBaseWords = {
  'null',
  'eins',
  'ein',
  'eine',
  'zwei',
  'drei',
  'vier',
  'funf',
  'sechs',
  'sieben',
  'acht',
  'neun',
  'zehn',
  'elf',
  'zwolf',
  'dreizehn',
  'vierzehn',
  'funfzehn',
  'sechzehn',
  'siebzehn',
  'achtzehn',
  'neunzehn',
  'zwanzig',
  'dreissig',
  'vierzig',
  'funfzig',
  'sechzig',
  'siebzig',
  'achtzig',
  'neunzig',
  'hundert',
  'tausend',
};
const _deMorphemes = [
  'dreissig',
  'dreizehn',
  'vierzehn',
  'funfzehn',
  'sechzehn',
  'siebzehn',
  'achtzehn',
  'neunzehn',
  'zwanzig',
  'vierzig',
  'funfzig',
  'sechzig',
  'siebzig',
  'achtzig',
  'neunzig',
  'hundert',
  'tausend',
  'sieben',
  'sechs',
  'zwolf',
  'eins',
  'eine',
  'zwei',
  'drei',
  'vier',
  'funf',
  'acht',
  'neun',
  'zehn',
  'ein',
  'elf',
  'und',
];

const _itUnits = {
  'uno': 1,
  'una': 1,
  'un': 1,
  'due': 2,
  'tre': 3,
  'quattro': 4,
  'cinque': 5,
  'sei': 6,
  'sette': 7,
  'otto': 8,
  'nove': 9,
};
const _itTeens = {
  'dieci': 10,
  'undici': 11,
  'dodici': 12,
  'tredici': 13,
  'quattordici': 14,
  'quindici': 15,
  'sedici': 16,
  'diciassette': 17,
  'diciotto': 18,
  'diciannove': 19,
};
const _itTens = {
  'venti': 20,
  'trenta': 30,
  'quaranta': 40,
  'cinquanta': 50,
  'sessanta': 60,
  'settanta': 70,
  'ottanta': 80,
  'novanta': 90,
};
const _itBaseWords = {
  'zero',
  'uno',
  'una',
  'un',
  'due',
  'tre',
  'quattro',
  'cinque',
  'sei',
  'sette',
  'otto',
  'nove',
  'dieci',
  'undici',
  'dodici',
  'tredici',
  'quattordici',
  'quindici',
  'sedici',
  'diciassette',
  'diciotto',
  'diciannove',
  'venti',
  'trenta',
  'quaranta',
  'cinquanta',
  'sessanta',
  'settanta',
  'ottanta',
  'novanta',
  'cento',
  'mille',
  'mila',
};
const List<({String canonical, List<String> followedBy, String prefix})>
_itElidedMorphemes = [
  (
    prefix: 'cinquant',
    canonical: 'cinquanta',
    followedBy: ['uno', 'un', 'otto'],
  ),
  (prefix: 'quarant', canonical: 'quaranta', followedBy: ['uno', 'un', 'otto']),
  (prefix: 'sessant', canonical: 'sessanta', followedBy: ['uno', 'un', 'otto']),
  (prefix: 'settant', canonical: 'settanta', followedBy: ['uno', 'un', 'otto']),
  (prefix: 'ottant', canonical: 'ottanta', followedBy: ['uno', 'un', 'otto']),
  (prefix: 'novant', canonical: 'novanta', followedBy: ['uno', 'un', 'otto']),
  (prefix: 'trent', canonical: 'trenta', followedBy: ['uno', 'un', 'otto']),
  (prefix: 'vent', canonical: 'venti', followedBy: ['uno', 'un', 'otto']),
  (
    prefix: 'cent',
    canonical: 'cento',
    followedBy: ['uno', 'un', 'ottanta', 'otto'],
  ),
];
const _itMorphemes = [
  'diciassette',
  'quattordici',
  'diciannove',
  'cinquanta',
  'quindici',
  'quaranta',
  'sessanta',
  'settanta',
  'diciotto',
  'quattro',
  'tredici',
  'ottanta',
  'novanta',
  'undici',
  'dodici',
  'sedici',
  'trenta',
  'cinque',
  'dieci',
  'sette',
  'venti',
  'cento',
  'mille',
  'mila',
  'otto',
  'nove',
  'uno',
  'una',
  'due',
  'tre',
  'sei',
  'un',
];

const _ptUnits = {
  'um': 1,
  'uma': 1,
  'dois': 2,
  'duas': 2,
  'tres': 3,
  'quatro': 4,
  'cinco': 5,
  'seis': 6,
  'sete': 7,
  'oito': 8,
  'nove': 9,
};
const _ptTeens = {
  'dez': 10,
  'onze': 11,
  'doze': 12,
  'treze': 13,
  'catorze': 14,
  'quatorze': 14,
  'quinze': 15,
  'dezesseis': 16,
  'dezasseis': 16,
  'dezessete': 17,
  'dezassete': 17,
  'dezoito': 18,
  'dezenove': 19,
  'dezanove': 19,
};
const _ptTens = {
  'vinte': 20,
  'trinta': 30,
  'quarenta': 40,
  'cinquenta': 50,
  'sessenta': 60,
  'setenta': 70,
  'oitenta': 80,
  'noventa': 90,
};

const _nlUnits = {
  'een': 1,
  'twee': 2,
  'drie': 3,
  'vier': 4,
  'vijf': 5,
  'zes': 6,
  'zeven': 7,
  'acht': 8,
  'negen': 9,
};
const _nlTeens = {
  'tien': 10,
  'elf': 11,
  'twaalf': 12,
  'dertien': 13,
  'veertien': 14,
  'vijftien': 15,
  'zestien': 16,
  'zeventien': 17,
  'achttien': 18,
  'negentien': 19,
};
const _nlTens = {
  'twintig': 20,
  'dertig': 30,
  'veertig': 40,
  'vijftig': 50,
  'zestig': 60,
  'zeventig': 70,
  'tachtig': 80,
  'negentig': 90,
};
const _nlBaseWords = {
  'nul',
  'een',
  'twee',
  'drie',
  'vier',
  'vijf',
  'zes',
  'zeven',
  'acht',
  'negen',
  'tien',
  'elf',
  'twaalf',
  'dertien',
  'veertien',
  'vijftien',
  'zestien',
  'zeventien',
  'achttien',
  'negentien',
  'twintig',
  'dertig',
  'veertig',
  'vijftig',
  'zestig',
  'zeventig',
  'tachtig',
  'negentig',
  'honderd',
  'duizend',
};
const _nlMorphemes = [
  'zeventien',
  'negentien',
  'veertien',
  'vijftien',
  'achttien',
  'zeventig',
  'negentig',
  'dertien',
  'zestien',
  'twintig',
  'veertig',
  'vijftig',
  'tachtig',
  'honderd',
  'duizend',
  'twaalf',
  'dertig',
  'zestig',
  'zeven',
  'negen',
  'twee',
  'drie',
  'vier',
  'vijf',
  'acht',
  'tien',
  'een',
  'zes',
  'elf',
  'en',
];

// Alignment ------------------------------------------------------------------

/// The alignment of [expected] with [heard]: each expected key's status
/// and whether each heard key was used.
({List<AnswerWordStatus> expected, List<bool> heard}) _align(
  List<String> expected,
  List<String> heard,
) {
  final n = expected.length;
  final m = heard.length;
  // score[i][j]: the best weight aligning expected[i..] with heard[j..]
  // (2 a match, 1 a close word).
  final score = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  int pair(int i, int j) {
    final a = expected[i];
    final b = heard[j];
    if (a == b) return 2;
    return _isClose(a, b) ? 1 : 0;
  }

  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      final weight = pair(i, j);
      score[i][j] = math.max(
        weight == 0 ? 0 : weight + score[i + 1][j + 1],
        math.max(score[i + 1][j], score[i][j + 1]),
      );
    }
  }
  final statuses = List.filled(n, AnswerWordStatus.missed);
  final used = List.filled(m, false);
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    final weight = pair(i, j);
    if (weight > 0 && score[i][j] == weight + score[i + 1][j + 1]) {
      statuses[i] = weight == 2
          ? AnswerWordStatus.matched
          : AnswerWordStatus.close;
      used[j] = true;
      i++;
      j++;
    } else if (score[i + 1][j] >= score[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return (expected: statuses, heard: used);
}

/// Whether [a] and [b] are a letter or two apart (one edit from 4
/// letters, two from 8); digits must be equal.
bool _isClose(String a, String b) {
  final shorter = math.min(a.length, b.length);
  if (shorter < 4) return false;
  if (RegExp(r'\d').hasMatch(a) || RegExp(r'\d').hasMatch(b)) return false;
  final limit = shorter >= 8 ? 2 : 1;
  if ((a.length - b.length).abs() > limit) return false;
  return _editDistance(a, b, limit) <= limit;
}

/// The Levenshtein distance of [a] and [b], or more than [limit] once it
/// is sure to exceed it.
int _editDistance(String a, String b, int limit) {
  final x = a.runes.toList();
  final y = b.runes.toList();
  var previous = List.generate(y.length + 1, (j) => j);
  for (var i = 1; i <= x.length; i++) {
    final current = List.filled(y.length + 1, 0)..[0] = i;
    var best = current[0];
    for (var j = 1; j <= y.length; j++) {
      final cost = x[i - 1] == y[j - 1] ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
      best = math.min(best, current[j]);
    }
    if (best > limit) return limit + 1;
    previous = current;
  }
  return previous[y.length];
}

/// Lower-case letters with diacritics and the letters they fold to
/// ([_plain], one for one): Latin, Vietnamese and Greek, from Unicode's
/// canonical decompositions (generated with Python's `unicodedata`), and
/// Russian ё.
const _accented =
    'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăąćĉċčďēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏő'
    'ŕŗřśŝşšţťũūŭůűųŵŷźżžơưǎǐǒǔǖǘǚǜǟǡǣǧǩǫǭǯǰǵǹǻǽǿȁȃȅȇȉȋȍȏȑȓȕȗșțȟȧ'
    'ȩȫȭȯȱȳḁḃḅḇḉḋḍḏḑḓḕḗḙḛḝḟḡḣḥḧḩḫḭḯḱḳḵḷḹḻḽḿṁṃṅṇṉṋṍṏṑṓṕṗṙṛṝṟṡṣṥṧṩṫ'
    'ṭṯṱṳṵṷṹṻṽṿẁẃẅẇẉẋẍẏẑẓẕẖẗẘẙẛạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợ'
    'ụủứừửữựỳỵỷỹΐάέήίΰϊϋόύώἀἁἂἃἄἅἆἇἐἑἒἓἔἕἠἡἢἣἤἥἦἧἰἱἲἳἴἵἶἷὀὁὂὃὄὅὐὑ'
    'ὒὓὔὕὖὗὠὡὢὣὤὥὦὧὰάὲέὴήὶίὸόὺύὼώᾀᾁᾂᾃᾄᾅᾆᾇᾐᾑᾒᾓᾔᾕᾖᾗᾠᾡᾢᾣᾤᾥᾦᾧᾰᾱᾲᾳᾴᾶᾷῂ'
    'ῃῄῆῇῐῑῒΐῖῗῠῡῢΰῤῥῦῧῲῳῴῶῷё';
const _plain =
    'aaaaaaceeeeiiiinooooouuuuyyaaaccccdeeeeegggghiiiijklllnnnooo'
    'rrrssssttuuuuuuwyzzzouaiouuuuuaaægkooʒjgnaæøaaeeiioorruustha'
    'eooooyabbbcdddddeeeeefghhhhhiikkkllllmmmnnnnoooopprrrrssssst'
    'tttuuuuuvvwwwwwxxyzzzhtwyſaaaaaaaaaaaaeeeeeeeeiioooooooooooo'
    'uuuuuuuyyyyιαεηιυιυουωααααααααεεεεεεηηηηηηηηιιιιιιιιοοοοοουυ'
    'υυυυυυωωωωωωωωααεεηηιιοουυωωααααααααηηηηηηηηωωωωωωωωαααααααη'
    'ηηηηιιιιιιυυυυρρυυωωωωωе';
