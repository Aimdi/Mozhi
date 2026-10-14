import 'dart:math' as math;

import 'package:equatable/equatable.dart';
// Grapheme clusters, counted like the input field's character count.
import 'package:flutter/widgets.dart' show StringCharacters;

/// Rudolf Flesch's interpretation bands for [WritingStats.fleschReadingEase].
enum FleschBand {
  /// 90–100.
  veryEasy,

  /// 80–90.
  easy,

  /// 70–80.
  fairlyEasy,

  /// 60–70: plain English.
  standard,

  /// 50–60.
  fairlyDifficult,

  /// 30–50.
  difficult,

  /// 0–30.
  veryDifficult;

  /// The band of a reading-ease [score].
  static FleschBand of(double score) => switch (score) {
    >= 90 => veryEasy,
    >= 80 => easy,
    >= 70 => fairlyEasy,
    >= 60 => standard,
    >= 50 => fairlyDifficult,
    >= 30 => difficult,
    _ => veryDifficult,
  };
}

/// Writing statistics of a text, computed locally (nothing is sent
/// anywhere). See [WritingStats.of] for how each figure is counted.
class WritingStats extends Equatable {
  const new({
    this.words = 0,
    this.characters = 0,
    this.sentences = 0,
    this.paragraphs = 0,
    this.readingTime = Duration.zero,
    this.fleschReadingEase,
  });

  /// Counts the statistics of [text].
  ///
  /// * [words]: runs of letters, marks and digits, joined by apostrophes and
  ///   hyphens (`don't`, `well-known`) or by `.`, `,` and `:` between digits
  ///   (`3.14`, `1,000`, `10:30`); single letters joined by dots (`e.g.`,
  ///   `U.S.A.`) are one word. Emoji, symbols and punctuation are not words.
  ///   In scripts that do not separate words with spaces:
  ///   * each Chinese character and Japanese kana counts as a word (like
  ///     word processors do);
  ///   * Thai, Lao, Khmer and Burmese words are estimated: each run of the
  ///     script (between spaces, zero-width spaces, punctuation and digits)
  ///     counts as its letters (not combining vowel signs, tone marks and
  ///     other marks) divided by the script's [lettersPerWord], rounded, and
  ///     as at least one word. Finding the actual words needs a dictionary:
  ///     a single sentence can be off by a third or more, but no longer by
  ///     a factor of 5 to 10 (as when each run counted as one word);
  ///   * Tibetan counts syllables, which the tsheg `་` separates.
  /// * [characters]: user-perceived characters (grapheme clusters),
  ///   including spaces and line breaks, as in the input field.
  /// * [sentences]: parts of a line that contain a word and end in `.`, `!`,
  ///   `?`, `…`, `।`, `؟` (followed by a space or the end of the line), or in
  ///   `。`, `！`, `？`, Armenian `։`, Burmese `။`, Khmer `។`, Ethiopic `።`
  ///   or Tibetan `།`. Thai has no full stop, so a space between two Thai
  ///   words ends a sentence too, and so does the end of any line
  ///   (headings, list items). A `.` does not end a sentence:
  ///   * after a common abbreviation (`Mr.`, `vs.`, `e.g.`);
  ///   * after a single letter of a script with case (never after Hangul
  ///     or other syllables) when the next word starts with a lowercase
  ///     letter or a digit (`a.m. on`, `p. 5`), or when the letter is next
  ///     to another initial (`J. K. Rowling`, `z. B. Äpfel`), first in the
  ///     sentence (`J. Smith`) or a capital after a word (`John F.
  ///     Kennedy`, `met J. Smith`). The pronoun `I`, a letter that labels a
  ///     noun (`plan B.`, `vitamin C.`) and dotted capitals after a
  ///     lowercase word (`in the U.S. Then`) still end one.
  /// * [paragraphs]: lines that contain a word (like word processors, every
  ///   line break starts a paragraph; blank lines are not counted).
  /// * [readingTime]: [wordsPerMinute] words or [cjkCharactersPerMinute]
  ///   Chinese and Japanese characters a minute, rounded up to a second.
  /// * [fleschReadingEase]: only when [languageCode] is English (`en`,
  ///   `en-GB`, ...) and the text has a sentence; see [fleschScore].
  factory of(String text, {String? languageCode}) {
    if (text.trim().isEmpty) {
      return WritingStats(characters: text.characters.length);
    }
    final cjk = _cjk.allMatches(text).length;
    var rest = text.replaceAll(_cjk, ' ');
    var estimated = 0;
    for (final (run, lettersPerWord) in _spacelessRuns) {
      for (final match in run.allMatches(rest)) {
        final letters = _letter.allMatches(match[0]!).length;
        estimated += math.max(1, (letters / lettersPerWord).round());
      }
      rest = rest.replaceAll(run, ' ');
    }
    final tokens = [for (final match in _word.allMatches(rest)) match[0]!];
    final words = cjk + estimated + tokens.length;
    var sentences = 0;
    var paragraphs = 0;
    for (final line in text.split(_lineBreak)) {
      if (!_letterOrDigit.hasMatch(line)) continue;
      paragraphs++;
      sentences += _sentencesIn(line);
    }
    final minutes =
        (tokens.length + estimated) / wordsPerMinute +
        cjk / cjkCharactersPerMinute;
    double? flesch;
    if (isEnglish(languageCode) && tokens.isNotEmpty && sentences > 0) {
      flesch = fleschScore(
        words: tokens.length,
        sentences: sentences,
        syllables: tokens.fold(0, (sum, word) => sum + englishSyllables(word)),
      );
    }
    return WritingStats(
      words: words,
      characters: text.characters.length,
      sentences: sentences,
      paragraphs: paragraphs,
      readingTime: Duration(seconds: (minutes * 60).ceil()),
      fleschReadingEase: flesch,
    );
  }

  /// Average silent reading speed of adults for non-fiction in English
  /// (Brysbaert, 2019), used for every language written with spaces.
  static const wordsPerMinute = 238;

  /// Reading speed for Chinese characters and Japanese kana (Brysbaert,
  /// 2019, reports about 255 a minute for Chinese and 357 for Japanese).
  static const cjkCharactersPerMinute = 300;

  /// Average number of letters in a word (combining marks not counted),
  /// by Unicode script, for the scripts without spaces between words whose
  /// words [WritingStats.of] estimates. Measured on sample texts split into
  /// words by ICU's dictionary-based word breaker.
  static const lettersPerWord = {
    'Thai': 3.0,
    'Lao': 3.5,
    'Khmer': 3.5,
    'Myanmar': 2.5,
  };

  final int words;
  final int characters;
  final int sentences;
  final int paragraphs;
  final Duration readingTime;

  /// Flesch reading ease (0–100, higher is easier), or null when the text
  /// is not English or has no sentence.
  final double? fleschReadingEase;

  /// Words per sentence (0 without sentences).
  double get averageSentenceLength => sentences == 0 ? 0 : words / sentences;

  /// The band of [fleschReadingEase], or null.
  FleschBand? get fleschBand {
    final score = fleschReadingEase;
    return score == null ? null : FleschBand.of(score);
  }

  /// Whether [code] is an English language code (`en`, `en-GB`, `en_US`).
  static bool isEnglish(String? code) =>
      (code ?? '').trim().toLowerCase().split(RegExp('[-_]')).first == 'en';

  /// Flesch's reading-ease formula (1948):
  ///
  /// `206.835 − 1.015 × (words / sentences) − 84.6 × (syllables / words)`
  ///
  /// clamped to 0–100: higher scores are easier to read; 60–70 is plain
  /// English (see [FleschBand]). Syllables come from [englishSyllables].
  static double fleschScore({
    required int words,
    required int sentences,
    required int syllables,
  }) {
    if (words <= 0 || sentences <= 0) return 0;
    final score =
        206.835 - 1.015 * (words / sentences) - 84.6 * (syllables / words);
    return score.clamp(0, 100).toDouble();
  }

  /// An estimate of the syllables in an English [word]: its groups of one
  /// or two vowels (`y` counts as a vowel except at the start), after
  /// dropping a silent final `e` (`make`), `es` (`makes`, but not `boxes`)
  /// or `ed` (`jumped`, but not `wanted`). Words of up to three letters,
  /// numbers and words without Latin letters count as one syllable.
  static int englishSyllables(String word) {
    var letters = word.toLowerCase().replaceAll(_nonLatin, '');
    if (letters.length <= 3) return 1;
    letters = letters
        .replaceFirst(_silentEnding, '')
        .replaceFirst(_leadingY, '');
    return math.max(1, _vowelGroup.allMatches(letters).length);
  }

  static int _sentencesIn(String line) {
    var count = 0;
    var start = 0;
    for (final match in _terminator.allMatches(line)) {
      final terminator = match[0]!;
      if (terminator.startsWith('.') &&
          !terminator.startsWith('..') &&
          _isAbbreviation(
            line.substring(start, match.start),
            line.substring(match.end),
          )) {
        continue;
      }
      if (_letterOrDigit.hasMatch(line.substring(start, match.end))) count++;
      start = match.end;
    }
    if (_letterOrDigit.hasMatch(line.substring(start))) count++;
    return count;
  }

  /// Whether the `.` after [before] (the sentence so far) ends an
  /// abbreviation rather than the sentence; [after] is the rest of the
  /// line. See [WritingStats.of].
  static bool _isAbbreviation(String before, String after) {
    final token = _lastToken.firstMatch(before)?[1];
    if (token == null) return false;
    if (_abbreviations.contains(token.toLowerCase())) return true;
    final letter = token.substring(token.lastIndexOf('.') + 1);
    if (letter.characters.length != 1 || !_cased.hasMatch(letter)) {
      return false;
    }
    final next = _letterOrDigit.firstMatch(after)?[0];
    // A sentence does not start with a lowercase letter or a digit.
    if (next == null || _lowercaseOrDigit.hasMatch(next)) return true;
    final preceding = before.substring(0, before.length - token.length);
    // J. K. Rowling, z. B. Äpfel.
    if (_nextInitial.hasMatch(after) || _previousInitial.hasMatch(preceding)) {
      return true;
    }
    // Option a. Then ...; 5 p.m. Then ...
    if (!_uppercase.hasMatch(letter)) return false;
    final previous = _previousWord.firstMatch(preceding)?[1];
    if (previous == null) return true;
    if (token.contains('.')) return _uppercase.hasMatch(previous);
    return token != 'I' && !_labelNouns.contains(previous.toLowerCase());
  }

  /// Abbreviations that are rarely at the end of a sentence.
  static const _abbreviations = {
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'sr',
    'jr',
    'st',
    'vs',
    'cf',
    'e.g',
    'i.e',
    'approx',
    'fig',
    'vol',
    'pp',
    'ca',
    'bzw',
    'z.b',
    'd.h',
    'u.a',
    'nr',
    'hr',
    'sra',
    'mme',
    'mlle',
  };

  /// Nouns that a capital letter often labels at the end of a sentence
  /// (`plan B.`, `vitamin C.`), where it is not an initial.
  static const _labelNouns = {
    'answer',
    'appendix',
    'block',
    'category',
    'class',
    'column',
    'exhibit',
    'figure',
    'gate',
    'grade',
    'group',
    'hepatitis',
    'item',
    'level',
    'model',
    'option',
    'part',
    'phase',
    'plan',
    'point',
    'question',
    'room',
    'row',
    'section',
    'size',
    'step',
    'table',
    'team',
    'type',
    'version',
    'vitamin',
    'zone',
  };

  static final _cjk = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー]',
    unicode: true,
  );

  /// Runs of letters and marks of each script in [lettersPerWord].
  static final List<(RegExp, double)> _spacelessRuns = [
    for (final MapEntry(key: script, :value) in lettersPerWord.entries)
      (
        RegExp('(?:(?=\\p{Script=$script})[\\p{L}\\p{M}])+', unicode: true),
        value,
      ),
  ];
  static final _letter = RegExp(r'\p{L}', unicode: true);
  static final _word = RegExp(
    // Single letters joined by dots (e.g., U.S.A.), then other words.
    r'(?<![\p{L}\p{M}\p{N}])\p{L}\p{M}*(?:\.\p{L}\p{M}*)+(?![\p{L}\p{M}\p{N}])'
    r"|[\p{L}\p{M}\p{N}]+(?:(?:['’‐-]|(?<=\p{N})[.,:](?=\p{N}))"
    r'[\p{L}\p{M}\p{N}]+)*',
    unicode: true,
  );
  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _lineBreak = RegExp(r'\r\n|[\n\r\u2028\u2029]');
  static final _terminator = RegExp(
    r'''[.!?…‽।॥؟۔]+["'”’»)\]]*(?=\s|$)'''
    '|[。！？։။។៕።፧།༎]+[」』”’）]*'
    // A space between two Thai words (not after ฯ or around ๆ).
    r'|(?<=[\u0E01-\u0E2E\u0E30-\u0E3A\u0E40-\u0E45\u0E47-\u0E4E])\s+'
    r'(?=[\u0E01-\u0E2E\u0E40-\u0E44])',
  );

  /// The last word of a text, with any letters it is joined to by dots
  /// (`Mr`, `e.g`, `U.S`).
  static final _lastToken = RegExp(
    r'(?:^|[^\p{L}\p{M}.])((?:[\p{L}\p{M}]+\.)*[\p{L}\p{M}]+)$',
    unicode: true,
  );
  static final _previousWord = RegExp(r'(\p{L}+)[^\p{L}]*$', unicode: true);
  static final _previousInitial = RegExp(
    r'(?:^|[^\p{L}\p{M}])\p{L}\p{M}*\.\s+$',
    unicode: true,
  );
  static final _nextInitial = RegExp(r'^\s+\p{L}\p{M}*\.', unicode: true);
  static final _cased = RegExp(r'^[\p{Lu}\p{Ll}\p{Lt}]', unicode: true);
  static final _uppercase = RegExp(r'^[\p{Lu}\p{Lt}]', unicode: true);
  static final _lowercaseOrDigit = RegExp(r'^[\p{Ll}\p{N}]', unicode: true);
  static final _nonLatin = RegExp('[^a-z]');
  static final _silentEnding = RegExp(
    r'(?:[^laeiouyszxcgh]es|[^aeioutd]ed|[^laeiouy]e)$',
  );
  static final _leadingY = RegExp('^y');
  static final _vowelGroup = RegExp('[aeiouy]{1,2}');

  @override
  List<Object?> get props => [
    words,
    characters,
    sentences,
    paragraphs,
    readingTime,
    fleschReadingEase,
  ];
}
