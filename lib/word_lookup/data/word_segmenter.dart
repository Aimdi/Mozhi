import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/widgets.dart' show StringCharacters;

/// A word of a text: [text], from [start] to [end] (UTF-16 offsets, end
/// exclusive).
@immutable
class TextWord {
  const new(this.start, this.end, this.text);

  final int start;
  final int end;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is TextWord &&
      other.start == start &&
      other.end == end &&
      other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);

  @override
  String toString() => 'TextWord($start, $end, $text)';
}

/// The words a dictionary knows, for cutting text written without spaces
/// into words (the installed dictionary pack of the text's language).
abstract interface class WordIndex {
  /// Whether [word] is a word of the dictionary (a headword or a form).
  Future<bool> contains(String word);

  /// Whether a word of the dictionary starts with [prefix].
  Future<bool> hasPrefix(String prefix);
}

/// Scripts written without spaces between words, told apart so that a
/// word never mixes two of them.
enum _Unspaced { cjk, thai, lao, khmer, myanmar }

/// One grapheme cluster of a text.
typedef _Cluster = ({int start, int end, String text});

/// Finds the word at a position of a text, also in scripts written without
/// spaces.
///
/// * Scripts with spaces (Latin, Cyrillic, Greek, Arabic, Hebrew, Indic
///   scripts, Hangul, ...): the run of letters, digits and their marks
///   around the position, punctuation trimmed. Apostrophes, hyphens, the
///   Catalan middle dot, the Hebrew geresh and gershayim and the zero-width
///   (non-)joiner stay inside a word when letters follow on both sides
///   (`don't`, `E-Mail-Adresse`, `צה״ל`, Persian `می‌خواهم`). Compounds
///   are one word (`Donaudampfschifffahrt`). Digits alone are no word.
/// * Chinese, Japanese, Thai, Lao, Khmer and Myanmar: the longest word of
///   the dictionary ([WordIndex]) that covers the position, at most
///   [maxMatchLength] grapheme clusters long (twice that in the Southeast
///   Asian scripts, whose words have more clusters), the earliest of equal
///   length; without a dictionary, or when it has none, the one grapheme
///   cluster at the position.
/// * An emoji (or another symbol) is a word of its own, one grapheme
///   cluster with its modifiers and joiners.
///
/// Offsets are UTF-16 code units, as in Flutter's text selections; a
/// position right after a word (at its end) finds that word.
abstract final class WordSegmenter {
  /// Longest dictionary word tried in Chinese and Japanese, in grapheme
  /// clusters.
  static const maxMatchLength = 8;

  static final _letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _hasLetter = RegExp(r'\p{L}', unicode: true);
  static final _symbol = RegExp(
    r'[\p{S}\p{Extended_Pictographic}]',
    unicode: true,
  );

  /// Characters that join two parts of one word.
  static const _joiners = {
    "'", '’', 'ʼ', '‘', // Apostrophes (English, French, Ukrainian, ...).
    '-', '‐', '‑', // Hyphens.
    '\u00B7', '\u0387', // Catalan middle dot (l·l), Greek ano teleia.
    '׳', '״', '־', // Hebrew geresh, gershayim and maqaf.
    '\u200C', '\u200D', // Zero-width non-joiner (Persian) and joiner.
    '\u00AD', // Soft hyphen.
  };

  static final _scripts = <(RegExp, _Unspaced)>[
    (
      RegExp(
        r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
        '々〆〻ーｰ]',
        unicode: true,
      ),
      _Unspaced.cjk,
    ),
    (RegExp(r'\p{Script=Thai}', unicode: true), _Unspaced.thai),
    (RegExp(r'\p{Script=Lao}', unicode: true), _Unspaced.lao),
    (RegExp(r'\p{Script=Khmer}', unicode: true), _Unspaced.khmer),
    (RegExp(r'\p{Script=Myanmar}', unicode: true), _Unspaced.myanmar),
  ];

  /// The script without spaces [cluster] is written in, or null.
  static _Unspaced? _unspaced(String cluster) {
    for (final (pattern, script) in _scripts) {
      if (pattern.hasMatch(cluster)) return script;
    }
    return null;
  }

  /// Whether [cluster] is written in a script without spaces between
  /// words (Chinese, Japanese, Thai, Lao, Khmer, Myanmar).
  static bool writtenWithoutSpaces(String cluster) =>
      _unspaced(cluster) != null;

  static List<_Cluster> _clusters(String text) {
    final clusters = <_Cluster>[];
    var offset = 0;
    for (final cluster in text.characters) {
      final end = offset + cluster.length;
      clusters.add((start: offset, end: end, text: cluster));
      offset = end;
    }
    return clusters;
  }

  static bool _isLetter(String cluster) => _letter.hasMatch(cluster);

  /// The cluster at [offset] (the one before it when [offset] is at the end
  /// of a word or of the text), or -1.
  static int _clusterAt(List<_Cluster> clusters, int offset) {
    if (clusters.isEmpty) return -1;
    var index = clusters.indexWhere(
      (cluster) => cluster.start <= offset && offset < cluster.end,
    );
    if (index < 0) index = clusters.length - 1;
    final here = clusters[index].text;
    if (!_isLetter(here) &&
        !_symbol.hasMatch(here) &&
        index > 0 &&
        clusters[index].start == offset &&
        _isLetter(clusters[index - 1].text)) {
      index--;
    }
    return index;
  }

  static TextWord _word(
    String text,
    List<_Cluster> clusters,
    int from,
    int to,
  ) {
    final start = clusters[from].start;
    final end = clusters[to - 1].end;
    return TextWord(start, end, text.substring(start, end));
  }

  /// The word at [offset] of [text] without a dictionary: in a script
  /// without spaces, the one grapheme cluster there. Null on white space,
  /// punctuation and digits alone.
  static TextWord? wordAt(String text, int offset) {
    final clusters = _clusters(text);
    final index = _clusterAt(clusters, offset.clamp(0, text.length));
    if (index < 0) return null;
    return _spacedWord(text, clusters, index);
  }

  /// The word at [offset] of [text], with the words of [index] for scripts
  /// written without spaces (see the class docs). Null on white space,
  /// punctuation and digits alone.
  static Future<TextWord?> lookUpWordAt(
    String text,
    int offset, {
    WordIndex? index,
  }) async {
    final clusters = _clusters(text);
    final at = _clusterAt(clusters, offset.clamp(0, text.length));
    if (at < 0) return null;
    final script = _unspaced(clusters[at].text);
    if (script == null || index == null) {
      return _spacedWord(text, clusters, at);
    }
    return await _longestMatch(text, clusters, at, script, index) ??
        _word(text, clusters, at, at + 1);
  }

  static TextWord? _spacedWord(
    String text,
    List<_Cluster> clusters,
    int index,
  ) {
    final here = clusters[index].text;
    if (_unspaced(here) != null) return _word(text, clusters, index, index + 1);
    if (!_isLetter(here)) {
      return _symbol.hasMatch(here)
          ? _word(text, clusters, index, index + 1)
          : null;
    }
    bool inWord(int i) =>
        i >= 0 &&
        i < clusters.length &&
        _isLetter(clusters[i].text) &&
        _unspaced(clusters[i].text) == null;
    bool joins(int i) => _joiners.contains(clusters[i].text);
    var from = index;
    while (true) {
      if (inWord(from - 1)) {
        from--;
      } else if (from - 2 >= 0 && joins(from - 1) && inWord(from - 2)) {
        from -= 2;
      } else {
        break;
      }
    }
    var to = index + 1;
    while (true) {
      if (inWord(to)) {
        to++;
      } else if (to + 1 < clusters.length && joins(to) && inWord(to + 1)) {
        to += 2;
      } else {
        break;
      }
    }
    final word = _word(text, clusters, from, to);
    return _hasLetter.hasMatch(word.text) ? word : null;
  }

  /// The longest word of [index] in the run of [script] around the cluster
  /// [at] that covers it (the earliest of equal length), or null.
  static Future<TextWord?> _longestMatch(
    String text,
    List<_Cluster> clusters,
    int at,
    _Unspaced script,
    WordIndex index,
  ) async {
    final longest = script == _Unspaced.cjk
        ? maxMatchLength
        : maxMatchLength * 2;
    bool sameScript(int i) => _unspaced(clusters[i].text) == script;
    var runStart = at;
    while (runStart > 0 &&
        at - runStart + 1 < longest &&
        sameScript(runStart - 1)) {
      runStart--;
    }
    var runEnd = at + 1;
    while (runEnd < clusters.length &&
        runEnd - at < longest &&
        sameScript(runEnd)) {
      runEnd++;
    }
    String part(int from, int to) =>
        text.substring(clusters[from].start, clusters[to - 1].end);
    TextWord? best;
    var bestLength = 1;
    for (var from = runStart; from <= at; from++) {
      // Every candidate from here contains the clusters up to [at].
      if (!await index.hasPrefix(part(from, at + 1))) continue;
      final last = from + longest < runEnd ? from + longest : runEnd;
      for (var to = last; to > at; to--) {
        final length = to - from;
        if (length <= bestLength) break;
        if (await index.contains(part(from, to))) {
          best = _word(text, clusters, from, to);
          bestLength = length;
          break;
        }
      }
    }
    return best;
  }

  /// Sentence ends: the text around a word stops after them.
  static final _sentenceEnd = RegExp('[.!?…。！？｡\n؟۔।]');

  /// The sentence of [text] that [word] is in (trimmed), at most
  /// [maxLength] code units around the word: context for a dictionary.
  static String sentenceAround(
    String text,
    TextWord word, {
    int maxLength = 300,
  }) {
    var start = 0;
    for (final match in _sentenceEnd.allMatches(text)) {
      if (match.end > word.start) break;
      start = match.end;
    }
    var end = text.length;
    final next = _sentenceEnd.firstMatch(text.substring(word.end));
    if (next != null) end = word.end + next.end;
    if (end - start > maxLength) {
      final half = (maxLength - (word.end - word.start)) ~/ 2;
      start = (word.start - half).clamp(start, word.start);
      end = (word.end + half).clamp(word.end, end);
      if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
      if (end < text.length && _isLowSurrogate(text.codeUnitAt(end))) end++;
    }
    return text.substring(start, end).trim();
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
}
