import 'dart:math' as math;
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

/// How a [MemoryMatch] relates to the looked-up text.
enum MemoryMatchKind {
  /// The normalised texts are equal ([TranslationMemory.normalize]).
  exact,

  /// The texts are similar ([TranslationMemory.similarity] at least
  /// [TranslationMemory.threshold]).
  similar,
}

/// What a [MemoryDiffSegment] is in a comparison of the history entry's
/// text with the looked-up text.
enum MemoryDiffOp {
  /// In both texts.
  equal,

  /// Only in the history entry's text.
  removed,

  /// Only in the looked-up text.
  added,
}

/// A run of words (or characters, for text without spaces) of a
/// [MemoryMatch.diff]. Joining the [text] of all segments gives both texts
/// interleaved; leaving out [MemoryDiffOp.added] gives the history text
/// (with normalised spacing), leaving out [MemoryDiffOp.removed] the
/// looked-up one.
class MemoryDiffSegment extends Equatable {
  const new(this.text, this.op);

  /// The words, with the separator before them when this is not the first
  /// segment.
  final String text;
  final MemoryDiffOp op;

  @override
  List<Object?> get props => [text, op];

  @override
  String toString() => '${op.name}(${text.replaceAll('\n', r'\n')})';
}

/// A history entry whose source text matches the looked-up text.
class MemoryMatch extends Equatable {
  const new({
    required this.entry,
    required this.kind,
    required this.similarity,
    this.diff = const [],
  });

  /// The earlier translation.
  final HistoryEntry entry;
  final MemoryMatchKind kind;

  /// 1 for an [MemoryMatchKind.exact] match, else the normalised
  /// Levenshtein similarity of the normalised texts (0..1).
  final double similarity;

  /// How [entry]'s text differs from the looked-up text (empty for an
  /// exact match).
  final List<MemoryDiffSegment> diff;

  bool get isExact => kind == MemoryMatchKind.exact;

  /// [similarity] as a whole percentage (rounded down, so 0.999 is 99).
  int get percent => (similarity * 100).floor();

  @override
  List<Object?> get props => [entry, kind, similarity, diff];
}

/// Finds earlier translations of (nearly) the same text in the local
/// history: offline and free.
///
/// * **Exact**: the trimmed, lower-cased, whitespace-collapsed texts are
///   equal ([normalize]).
/// * **Similar**: for texts of at least [minFuzzyLength] (and at most
///   [maxFuzzyLength]) normalised characters, the normalised Levenshtein
///   similarity ([similarity]) is at least [threshold]. Candidates are
///   pre-filtered by length and trigram overlap, and only the
///   [maxCandidates] most promising ones are compared exactly (with a
///   banded edit distance), so a lookup stays cheap enough to run on every
///   keystroke.
///
/// Only the [maxEntries] newest entries are considered. An entry matches
/// only for a compatible language pair: the same target (codes compared
/// with [LanguageMatcher.normalize]) and, unless the looked-up source is
/// auto, the same source (an entry with an auto source counts when its
/// detected language is that source or unknown). Entries with an empty
/// text or translation never match.
///
/// Normalised texts and trigrams are cached per entry instance.
class TranslationMemory {
  new({
    this.maxEntries = 500,
    this.minFuzzyLength = 20,
    this.maxFuzzyLength = 2000,
    this.threshold = 0.85,
    this.maxCandidates = 8,
  }) : assert(threshold > 0 && threshold <= 1, 'threshold must be in (0, 1]');

  /// How many of the newest entries are searched.
  final int maxEntries;

  /// Shortest normalised text (both the looked-up one and the entry's)
  /// that may match approximately.
  final int minFuzzyLength;

  /// Longest normalised looked-up text that is matched approximately
  /// (longer text only matches exactly).
  final int maxFuzzyLength;

  /// Lowest [similarity] of a [MemoryMatchKind.similar] match.
  final double threshold;

  /// Most candidates whose edit distance is computed per lookup.
  final int maxCandidates;

  final Expando<_Indexed> _index = Expando('TranslationMemory');

  static final _spaces = RegExp(r'\s+');

  /// [text] trimmed, lower-cased and with every run of whitespace replaced
  /// by one space.
  static String normalize(String text) =>
      text.trim().toLowerCase().replaceAll(_spaces, ' ');

  /// The best match for [text] among [entries] (newest first), or null.
  ///
  /// An exact match wins over a similar one (the newest of each kind; of
  /// similar ones the most similar). Non-favourite entries created more
  /// than [maxAge] before [now] (history retention) are skipped. Entries
  /// whose id is in [excludeFuzzy] never match approximately (e.g. the
  /// entries recorded while the text was being typed).
  MemoryMatch? lookup(
    String text, {
    required Language source,
    required Language target,
    required Iterable<HistoryEntry> entries,
    Duration? maxAge,
    DateTime? now,
    Set<String> excludeFuzzy = const {},
  }) {
    final query = normalize(text);
    if (query.isEmpty) return null;
    final cutoff = maxAge == null
        ? null
        : (now ?? DateTime.now()).subtract(maxAge);
    final fuzzy =
        query.length >= minFuzzyLength && query.length <= maxFuzzyLength;
    final candidates = <({_Indexed indexed, double score, int order})>[];
    Set<String>? queryTrigrams;
    var seen = 0;
    for (final entry in entries) {
      if (seen++ >= maxEntries) break;
      if (cutoff != null &&
          !entry.isFavorite &&
          entry.createdAt.isBefore(cutoff)) {
        continue;
      }
      if (entry.translation.trim().isEmpty ||
          !_compatible(entry, source: source, target: target)) {
        continue;
      }
      final indexed = _indexed(entry);
      if (indexed.text.isEmpty) continue;
      if (indexed.text == query) {
        return MemoryMatch(
          entry: entry,
          kind: MemoryMatchKind.exact,
          similarity: 1,
        );
      }
      if (!fuzzy ||
          indexed.text.length < minFuzzyLength ||
          excludeFuzzy.contains(entry.id) ||
          _maxDistance(query.length, indexed.text.length) <
              (query.length - indexed.text.length).abs()) {
        continue;
      }
      final trigrams = queryTrigrams ??= _trigrams(query);
      final score = _dice(trigrams, indexed.trigrams);
      // Each edit changes at most three trigrams: at the threshold most
      // trigrams are shared.
      if (score < _minDice) continue;
      candidates.add((indexed: indexed, score: score, order: seen));
    }
    if (candidates.isEmpty) return null;
    // Equally promising candidates stay newest first.
    candidates.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.order.compareTo(b.order);
    });
    MemoryMatch? best;
    for (final candidate in candidates.take(maxCandidates)) {
      final other = candidate.indexed.text;
      final longest = math.max(query.length, other.length);
      final distance = boundedLevenshtein(
        query,
        other,
        _maxDistance(query.length, other.length),
      );
      if (distance == null) continue;
      final value = 1 - distance / longest;
      if (best == null || value > best.similarity) {
        best = MemoryMatch(
          entry: candidate.indexed.entry,
          kind: MemoryMatchKind.similar,
          similarity: value,
          diff: diff(candidate.indexed.entry.text, text),
        );
      }
    }
    return best;
  }

  /// Lowest trigram overlap of a candidate worth an exact comparison.
  static const _minDice = 0.4;

  /// Most edits between texts of these lengths at [threshold].
  int _maxDistance(int a, int b) =>
      ((1 - threshold) * math.max(a, b) + 1e-9).floor();

  _Indexed _indexed(HistoryEntry entry) =>
      _index[entry] ??= _Indexed(entry, normalize(entry.text));

  static bool _compatible(
    HistoryEntry entry, {
    required Language source,
    required Language target,
  }) {
    if (!_sameLanguage(entry.target, target)) return false;
    if (source.isAuto) return true;
    if (!entry.source.isAuto) return _sameLanguage(entry.source, source);
    final detected = entry.detectedSource?.trim();
    if (detected == null || detected.isEmpty || source.isCustom) {
      return detected == null || detected.isEmpty;
    }
    return LanguageMatcher.normalize(detected) ==
        LanguageMatcher.normalize(source.code);
  }

  static bool _sameLanguage(Language a, Language b) {
    if (a.isCustom || b.isCustom) {
      return a.isCustom && b.isCustom && normalize(a.code) == normalize(b.code);
    }
    return LanguageMatcher.normalize(a.code) ==
        LanguageMatcher.normalize(b.code);
  }

  /// Normalised Levenshtein similarity of the normalised texts: 1 minus the
  /// edit distance divided by the longer length (1 for equal texts).
  static double similarity(String a, String b) {
    final x = normalize(a);
    final y = normalize(b);
    final longest = math.max(x.length, y.length);
    if (longest == 0) return 1;
    return 1 - boundedLevenshtein(x, y, longest)! / longest;
  }

  /// The edit distance of [a] and [b] (UTF-16 code units) when it is at
  /// most [max], else null. Only a band of width `2 * max + 1` is
  /// computed: O(length * max).
  static int? boundedLevenshtein(String a, String b, int max) {
    if (max < 0) return null;
    if ((a.length - b.length).abs() > max) return null;
    if (a == b) return 0;
    // [s] is the shorter text.
    final (s, t) = a.length <= b.length ? (a, b) : (b, a);
    final n = s.length;
    final m = t.length;
    if (n == 0) return m <= max ? m : null;
    final big = max + 1;
    var previous = Int32List(m + 1);
    var current = Int32List(m + 1);
    for (var j = 0; j <= m; j++) {
      previous[j] = j <= max ? j : big;
    }
    for (var i = 1; i <= n; i++) {
      final from = math.max(1, i - max);
      final to = math.min(m, i + max);
      current[0] = i <= max ? i : big;
      if (from > 1) current[from - 1] = big;
      var rowMin = current[0];
      final unit = s.codeUnitAt(i - 1);
      for (var j = from; j <= to; j++) {
        final cost = unit == t.codeUnitAt(j - 1) ? 0 : 1;
        var value = previous[j - 1] + cost;
        final deletion = previous[j] + 1;
        if (deletion < value) value = deletion;
        final insertion = current[j - 1] + 1;
        if (insertion < value) value = insertion;
        if (value > big) value = big;
        current[j] = value;
        if (value < rowMin) rowMin = value;
      }
      if (to < m) current[to + 1] = big;
      if (rowMin > max) return null;
      final swap = previous;
      previous = current;
      current = swap;
    }
    final distance = previous[m];
    return distance <= max ? distance : null;
  }

  /// Word-level difference between [from] (the history text) and [to] (the
  /// looked-up text), compared case-insensitively. Text with fewer than
  /// four words on both sides (e.g. scripts without spaces) is compared
  /// per character. Adjacent tokens of the same kind are merged.
  static List<MemoryDiffSegment> diff(String from, String to) {
    final a = from.trim();
    final b = to.trim();
    final words = a.split(_spaces).length >= 4 || b.split(_spaces).length >= 4;
    final List<String> x;
    final List<String> y;
    final String separator;
    if (words) {
      x = a.isEmpty ? const [] : a.split(_spaces);
      y = b.isEmpty ? const [] : b.split(_spaces);
      separator = ' ';
    } else {
      x = [for (final rune in a.runes) String.fromCharCode(rune)];
      y = [for (final rune in b.runes) String.fromCharCode(rune)];
      separator = '';
    }
    final ops = _lcsOps(x, y);
    final segments = <MemoryDiffSegment>[];
    final buffer = StringBuffer();
    MemoryDiffOp? op;
    void flush() {
      if (op != null) segments.add(MemoryDiffSegment(buffer.toString(), op));
      buffer.clear();
    }

    var first = true;
    for (final (token, tokenOp) in ops) {
      if (tokenOp != op) {
        flush();
        op = tokenOp;
      }
      if (!first) buffer.write(separator);
      buffer.write(token);
      first = false;
    }
    flush();
    return segments;
  }

  /// The tokens of [x] and [y] in order, each marked as in both, only in
  /// [x] (removed) or only in [y] (added), from a longest common
  /// subsequence (case-insensitive). Removals come before additions.
  static List<(String, MemoryDiffOp)> _lcsOps(List<String> x, List<String> y) {
    final lx = [for (final token in x) token.toLowerCase()];
    final ly = [for (final token in y) token.toLowerCase()];
    // Common prefix and suffix need no table.
    var start = 0;
    while (start < lx.length && start < ly.length && lx[start] == ly[start]) {
      start++;
    }
    var end = 0;
    while (end < lx.length - start &&
        end < ly.length - start &&
        lx[lx.length - 1 - end] == ly[ly.length - 1 - end]) {
      end++;
    }
    final n = lx.length - start - end;
    final m = ly.length - start - end;
    final width = m + 1;
    final table = Int32List((n + 1) * width);
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        table[i * width + j] = lx[start + i] == ly[start + j]
            ? table[(i + 1) * width + j + 1] + 1
            : math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
      }
    }
    final ops = <(String, MemoryDiffOp)>[
      for (var k = 0; k < start; k++) (y[k], MemoryDiffOp.equal),
    ];
    final removed = <(String, MemoryDiffOp)>[];
    final added = <(String, MemoryDiffOp)>[];
    void flushChanges() {
      ops
        ..addAll(removed)
        ..addAll(added);
      removed.clear();
      added.clear();
    }

    var i = 0;
    var j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && lx[start + i] == ly[start + j]) {
        flushChanges();
        ops.add((y[start + j], MemoryDiffOp.equal));
        i++;
        j++;
      } else if (j >= m ||
          (i < n && table[(i + 1) * width + j] >= table[i * width + j + 1])) {
        removed.add((x[start + i], MemoryDiffOp.removed));
        i++;
      } else {
        added.add((y[start + j], MemoryDiffOp.added));
        j++;
      }
    }
    flushChanges();
    for (var k = ly.length - end; k < ly.length; k++) {
      ops.add((y[k], MemoryDiffOp.equal));
    }
    return ops;
  }

  /// The set of character trigrams of [text] (padded with spaces).
  static Set<String> _trigrams(String text) {
    final padded = ' $text ';
    if (padded.length < 3) return {padded};
    return {
      for (var i = 0; i + 3 <= padded.length; i++) padded.substring(i, i + 3),
    };
  }

  /// Dice coefficient of two trigram sets.
  static double _dice(Set<String> a, Set<String> b) {
    if (a.isEmpty && b.isEmpty) return 1;
    final (small, large) = a.length <= b.length ? (a, b) : (b, a);
    var shared = 0;
    for (final trigram in small) {
      if (large.contains(trigram)) shared++;
    }
    return 2 * shared / (a.length + b.length);
  }
}

/// An entry with its normalised text and (lazily) trigrams.
class _Indexed {
  new(this.entry, this.text);

  final HistoryEntry entry;
  final String text;
  late final Set<String> trigrams = TranslationMemory._trigrams(text);
}
