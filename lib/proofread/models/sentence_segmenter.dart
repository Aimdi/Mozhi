import 'package:equatable/equatable.dart';

/// Where a sentence is in a text: the UTF-16 offsets [start] (inclusive)
/// and [end] (exclusive), without the whitespace around it.
class SentenceRange extends Equatable {
  const new(this.start, this.end) : assert(start <= end, 'start > end');

  final int start;
  final int end;

  /// The sentence in [text], the text it was found in.
  String of(String text) => text.substring(start, end);

  /// Whether [offset] lies in the sentence.
  bool contains(int offset) => offset >= start && offset < end;

  @override
  List<Object?> get props => [start, end];

  @override
  String toString() => 'SentenceRange($start, $end)';
}

/// A small rule-based sentence segmenter for tapping a sentence of a
/// result (good enough for UI purposes, not linguistics).
///
/// A sentence ends:
/// * after a run of terminal punctuation (`.`, `!`, `?`, `…`, `‽` and
///   the Arabic, Devanagari and similar full stops) with the closing quotes
///   and brackets right after it, when whitespace or the end of the text
///   follows;
/// * after the full-width CJK terminals (`。`, `！`, `？`, `｡`), also with
///   no space after them;
/// * at every line break (a line is never part of two sentences).
///
/// A full stop (or an ellipsis) does not end a sentence when the next word
/// starts with a lower-case letter (`e.g. this`, `wait... what`), after a
/// known abbreviation (`Dr.`, `e.g.`, `etc.`, `Nr.`, `bzw.`), inside or
/// after a chain of dotted single letters, spaced or not (`z. B.`,
/// `d. h.`, `u. a.`, `i. d. R.`, `U.S.A.`), after a single capital letter
/// (an initial: `J. Smith`), after a list number at the start of a line
/// (`1. First`), or after an ordinal number (`am 3. Oktober`,
/// `der 2. Platz`). When in doubt it keeps two sentences together rather
/// than cut one in two: a fragment is worse to rephrase than a pair. Text
/// that is all whitespace yields no sentence; the whitespace between
/// sentences belongs to none.
abstract final class SentenceSegmenter {
  /// The sentences of [text], in order.
  static List<SentenceRange> split(String text) {
    final sentences = <SentenceRange>[];
    void emit(int start, int end) {
      var s = start;
      var e = end;
      while (s < e && _isSpace(text.codeUnitAt(s))) {
        s++;
      }
      while (e > s && _isSpace(text.codeUnitAt(e - 1))) {
        e--;
      }
      if (s < e) sentences.add(SentenceRange(s, e));
    }

    var start = 0;
    var i = 0;
    final length = text.length;
    while (i < length) {
      final char = text[i];
      if (char == '\n' || char == '\r' || char == ' ' || char == ' ') {
        emit(start, i);
        start = i + 1;
        i++;
        continue;
      }
      if (!_terminals.contains(char)) {
        i++;
        continue;
      }
      // The run of terminals and the closing marks after it.
      var j = i;
      var fullWidth = false;
      while (j < length && _terminals.contains(text[j])) {
        if (_fullWidthTerminals.contains(text[j])) fullWidth = true;
        j++;
      }
      var k = j;
      while (k < length && _closers.contains(text[k])) {
        k++;
      }
      if (fullWidth ||
          ((k == length || _isSpace(text.codeUnitAt(k))) &&
              _endsSentence(text, start, i, j, k))) {
        emit(start, k);
        start = k;
      }
      i = k;
    }
    emit(start, length);
    return sentences;
  }

  /// Whether the terminal run [i, j) (closers up to [k]) followed by
  /// whitespace ends the sentence that started at [start].
  static bool _endsSentence(String text, int start, int i, int j, int k) {
    final run = text.substring(i, j);
    final continues = run == '.' || run == '…' || run == '...';
    if (!continues) return true;
    // The next word starts in lower case: the sentence goes on.
    final next = _nextVisible(text, k);
    if (next != null && _isLowerCase(next)) return false;
    if (run != '.') return true;
    if (_isAbbreviation(text, i)) return false;
    final word = _wordBefore(text, i);
    if (word.isEmpty) return true;
    if (_abbreviations.contains(word.toLowerCase())) return false;
    // An initial (J. Smith).
    if (word.length == 1 && _isUpperCase(word)) return false;
    if (_digits.hasMatch(word) && word.length <= 3) {
      // A list number at the start of a line (1. First).
      if (text.substring(start, i - word.length).trim().isEmpty) return false;
      if (_isOrdinal(text, i - word.length, k, word)) return false;
    }
    return true;
  }

  /// Whether the full stop at [dot] belongs to an abbreviation written as
  /// a chain of dotted words, with or without a space after each dot:
  /// `z. B.`, `d. h.`, `u. a.`, `i. d. R.`, `U.S.A.`, `e.g.`, `v. Chr.`.
  ///
  /// A chain of two or more single letters is always an abbreviation (or
  /// initials); other chains only when they are known ones.
  static bool _isAbbreviation(String text, int dot) {
    final segments = <String>[];
    // The words before the dot, back to the start of the chain.
    var end = dot;
    while (true) {
      var s = end;
      while (s > 0 && _isLetter(text[s - 1])) {
        s--;
      }
      if (s == end || !_chainable(text.substring(s, end), segments)) break;
      segments.insert(0, text.substring(s, end));
      var p = s;
      if (p > 0 && _isInlineSpace(text.codeUnitAt(p - 1))) p--;
      if (p > 0 && text[p - 1] == '.') {
        end = p - 1;
      } else {
        break;
      }
    }
    if (segments.isEmpty) return false;
    // The words after the dot, up to the end of the chain.
    var from = dot + 1;
    while (true) {
      var r = from;
      if (r < text.length && _isInlineSpace(text.codeUnitAt(r))) r++;
      var e = r;
      while (e < text.length && _isLetter(text[e])) {
        e++;
      }
      if (e == r || e >= text.length || text[e] != '.') break;
      if (!_chainable(text.substring(r, e), segments)) break;
      segments.add(text.substring(r, e));
      from = e + 1;
    }
    if (segments.length < 2) return false;
    if (segments.every((segment) => segment.length == 1)) return true;
    return _abbreviations.contains(segments.join('.').toLowerCase());
  }

  /// Whether [word] can join the chain [segments]: the first word of a
  /// chain always, a single letter, or a word of a known dotted
  /// abbreviation (`Chr` of `v. Chr.`).
  static bool _chainable(String word, List<String> segments) =>
      segments.isEmpty ||
      word.length == 1 ||
      _chainWords.contains(word.toLowerCase());

  /// The words of more than one letter in the known dotted abbreviations.
  static final Set<String> _chainWords = {
    for (final abbreviation in _abbreviations)
      if (abbreviation.contains('.'))
        for (final word in abbreviation.split('.'))
          if (word.length > 1) word,
  };

  /// Whether the number [number] that starts at [numberStart] and is
  /// followed by a full stop (and closers up to [k]) is an ordinal, as in
  /// German and other languages that write `3.` for "third":
  /// `am 3. Oktober`, `der 2. Platz`, `zum 1. Mal`.
  static bool _isOrdinal(String text, int numberStart, int k, String number) {
    final next = _wordAfter(text, k).toLowerCase();
    if (number.length <= 2 && _months.contains(next)) return true;
    return _ordinalLeads.contains(_wordEndingAt(text, numberStart));
  }

  /// The letters of the word that starts after the spaces at [from] (on
  /// the same line), or `''`.
  static String _wordAfter(String text, int from) {
    var s = from;
    while (s < text.length && _isInlineSpace(text.codeUnitAt(s))) {
      s++;
    }
    var e = s;
    while (e < text.length && _isLetter(text[e])) {
      e++;
    }
    return text.substring(s, e);
  }

  /// The lower-cased letters of the word that ends before the spaces
  /// right before [end] (on the same line), or `''`.
  static String _wordEndingAt(String text, int end) {
    var e = end;
    while (e > 0 && _isInlineSpace(text.codeUnitAt(e - 1))) {
      e--;
    }
    var s = e;
    while (s > 0 && _isLetter(text[s - 1])) {
      s--;
    }
    return text.substring(s, e).toLowerCase();
  }

  /// The letters and inner full stops right before [end] (`e.g` for
  /// `e.g.`), or the digits.
  static String _wordBefore(String text, int end) {
    var s = end;
    while (s > 0) {
      final char = text[s - 1];
      if (char == '.' || _isLetter(char) || _digits.hasMatch(char)) {
        s--;
      } else {
        break;
      }
    }
    return text.substring(s, end);
  }

  /// The first character at or after [from] that is not whitespace (null
  /// at a line break or the end).
  static String? _nextVisible(String text, int from) {
    for (var i = from; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x0A || unit == 0x0D) return null;
      if (!_isSpace(unit)) return text[i];
    }
    return null;
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 ||
      unit == 0x09 ||
      unit == 0x0A ||
      unit == 0x0D ||
      unit == 0x0B ||
      unit == 0x0C ||
      unit == 0xA0 ||
      unit == 0x1680 ||
      (unit >= 0x2000 && unit <= 0x200A) ||
      unit == 0x2028 ||
      unit == 0x2029 ||
      unit == 0x202F ||
      unit == 0x205F ||
      unit == 0x3000;

  /// Whitespace that does not break a line.
  static bool _isInlineSpace(int unit) =>
      _isSpace(unit) &&
      unit != 0x0A &&
      unit != 0x0D &&
      unit != 0x0B &&
      unit != 0x0C &&
      unit != 0x2028 &&
      unit != 0x2029;

  static bool _isLetter(String char) => _letter.hasMatch(char);

  static bool _isLowerCase(String char) =>
      _isLetter(char) &&
      char.toLowerCase() == char &&
      char.toUpperCase() != char;

  static bool _isUpperCase(String char) =>
      _isLetter(char) &&
      char.toUpperCase() == char &&
      char.toLowerCase() != char;

  static final _letter = RegExp(r'^\p{L}$', unicode: true);
  static final _digits = RegExp(r'^[0-9]+$');

  static const _fullWidthTerminals = {'。', '！', '？', '｡'};

  static const Set<String> _terminals = {
    '.',
    '!',
    '?',
    '…',
    '‽',
    '؟',
    '۔',
    '।',
    '॥',
    '։',
    '።',
    ..._fullWidthTerminals,
  };

  /// Closing quotes and brackets that stay with the sentence they end.
  static const _closers = {
    '"',
    "'",
    '”',
    '’',
    '»',
    '›',
    ')',
    ']',
    '}',
    '」',
    '』',
    '）',
    '】',
    '〉',
    '》',
    '〕',
  };

  /// Abbreviations (lower case, without the final full stop) after which
  /// a full stop does not end a sentence.
  static const _abbreviations = {
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'sr',
    'jr',
    'st',
    'mt',
    'vs',
    'e.g',
    'i.e',
    'cf',
    'viz',
    'approx',
    'fig',
    'figs',
    'no',
    'nos',
    'vol',
    'p',
    'pp',
    'ch',
    'sec',
    'dept',
    'inc',
    'ltd',
    'co',
    'corp',
    'gen',
    'gov',
    'col',
    'lt',
    'sgt',
    'capt',
    'rev',
    'hon',
    'ave',
    'blvd',
    'jan',
    'feb',
    'apr',
    'jun',
    'jul',
    'aug',
    'sep',
    'sept',
    'oct',
    'nov',
    'dec',
    'a.m',
    'p.m',
    'u.s',
    'u.k',
    'ca',
    'z.b',
    'd.h',
    'bzw',
    'usw',
    'vgl',
    'nr',
    'hr',
    'fr',
    'mme',
    'mlle',
    'sra',
    'srta',
    'etc',
    'usf',
    'evtl',
    'ggf',
    'inkl',
    'exkl',
    'zzgl',
    'bzgl',
    'bspw',
    'insb',
    'sog',
    'abs',
    'jh',
    'jhd',
    'mio',
    'mrd',
    'geb',
    'gest',
    'hrsg',
    'str',
    'tel',
    'n.chr',
    'v.chr',
    'p.ex',
    'env',
    'ud',
    'uds',
  };

  /// German month names (and their abbreviations) that follow an ordinal
  /// day (`am 3. Oktober`), lower case.
  static const _months = {
    'januar',
    'jänner',
    'februar',
    'feber',
    'märz',
    'april',
    'mai',
    'juni',
    'juli',
    'august',
    'september',
    'oktober',
    'november',
    'dezember',
    'jan',
    'feb',
    'mär',
    'apr',
    'jun',
    'jul',
    'aug',
    'sep',
    'sept',
    'okt',
    'nov',
    'dez',
  };

  /// Words that come right before an ordinal number (`der 2. Platz`,
  /// `zum 1. Mal`, `seit dem 5. Jahr`), lower case. Words that also end a
  /// sentence before a count are left out (`I am 25.`, `bis 5.`);
  /// `am 3. Oktober` and `bis 5. Mai` are caught by the month.
  static const _ordinalLeads = {
    'der',
    'die',
    'das',
    'den',
    'dem',
    'des',
    'im',
    'vom',
    'zum',
    'zur',
    'beim',
    'ins',
    'ein',
    'eine',
    'einem',
    'einen',
    'einer',
    'eines',
    'jeden',
    'jedem',
    'jede',
    'jeder',
    'jedes',
    'mein',
    'meine',
    'meinem',
    'meinen',
    'sein',
    'seine',
    'seinem',
    'seinen',
    'ihr',
    'ihre',
    'ihrem',
    'ihren',
    'unser',
    'unsere',
    'unserem',
    'unseren',
    'diese',
    'dieser',
    'diesem',
    'diesen',
    'dieses',
  };
}
