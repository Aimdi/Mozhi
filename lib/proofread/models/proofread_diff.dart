import 'dart:math' as math;
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// Kind of a [DiffSegment].
enum DiffType { unchanged, removed, inserted }

/// A run of text in an inline diff between the proofread input and the
/// corrected output.
class DiffSegment extends Equatable {
  const new(this.type, this.text, {this.editIndex});

  const new unchanged(String text, {int? editIndex})
    : this(DiffType.unchanged, text, editIndex: editIndex);

  const new removed(String text, {int? editIndex})
    : this(DiffType.removed, text, editIndex: editIndex);

  const new inserted(String text, {int? editIndex})
    : this(DiffType.inserted, text, editIndex: editIndex);

  final DiffType type;
  final String text;

  /// Index of the [ProofreadEdit] this segment belongs to, when known.
  final int? editIndex;

  @override
  List<Object?> get props => [type, text, editIndex];

  @override
  String toString() => 'DiffSegment(${type.name}, "$text", $editIndex)';
}

/// Where a [ProofreadEdit] was found in the proofread text.
class EditLocation extends Equatable {
  const new(this.start, this.end);

  final int start;
  final int end;

  @override
  List<Object?> get props => [start, end];
}

/// Pure helpers that apply proofreading edits and compute inline diffs.
abstract final class ProofreadDiff {
  /// Category of the edits added by [reconcile].
  static const otherCategory = 'other';

  /// Locates [edits] in [source].
  ///
  /// Edits are placed in list order. Each one matches the first occurrence
  /// of its `original` at or after the end of the previously placed edit,
  /// preferring occurrences on token boundaries so that a short original
  /// such as `a` or `is` does not land inside another word. An edit with no
  /// such occurrence (e.g. one listed out of order) falls back to the first
  /// occurrence anywhere that does not overlap an already placed edit.
  /// Edits whose original is empty or cannot be placed without overlapping
  /// are `null` and are skipped by [apply] and [editSegments]. Locations do
  /// not depend on which edits are accepted, so toggling one edit never
  /// moves another.
  static List<EditLocation?> locate(String source, List<ProofreadEdit> edits) {
    final locator = _Locator(source);
    return [for (final edit in edits) locator.add(edit.original)];
  }

  /// Applies the [accepted] edits (by index) to [source].
  static String apply(
    String source,
    List<ProofreadEdit> edits,
    Set<int> accepted,
  ) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final (index, location) in _ordered(locate(source, edits))) {
      if (!accepted.contains(index)) continue;
      buffer
        ..write(source.substring(cursor, location.start))
        ..write(edits[index].replacement);
      cursor = location.end;
    }
    buffer.write(source.substring(cursor));
    return buffer.toString();
  }

  /// Returns [edits] followed by one edit (category [otherCategory]) per
  /// change that [corrected] makes to [source] but none of [edits] lists, so
  /// every change in the corrected text can be reviewed and toggled.
  ///
  /// Where [corrected] disagrees with a listed edit, the listed edit wins.
  /// Returns [edits] itself when there is nothing to add (including when
  /// [corrected] is blank).
  static List<ProofreadEdit> reconcile(
    String source,
    List<ProofreadEdit> edits,
    String corrected,
  ) {
    if (corrected.trim().isEmpty) return edits;
    final locator = _Locator(source);
    final locations = [for (final edit in edits) locator.add(edit.original)];

    // Unchanged stretches of the source and where they are in the applied
    // text, so that changes in the applied text map back to the source.
    final gaps = <_Gap>[];
    final applied = StringBuffer();
    var cursor = 0;
    for (final (index, location) in _ordered(locations)) {
      gaps.add(_Gap(cursor, location.start, applied.length));
      applied
        ..write(source.substring(cursor, location.start))
        ..write(edits[index].replacement);
      cursor = location.end;
    }
    gaps.add(_Gap(cursor, source.length, applied.length));
    applied.write(source.substring(cursor));
    final appliedText = applied.toString();
    if (appliedText == corrected) return edits;

    final boundaries = _tokenBoundaries(source);
    final extra = <ProofreadEdit>[];
    final segments = wordDiff(appliedText, corrected);
    var position = 0;
    var i = 0;
    while (i < segments.length) {
      final segment = segments[i];
      if (segment.type == DiffType.unchanged) {
        position += segment.text.length;
        i++;
        continue;
      }
      var removed = '';
      var inserted = '';
      if (segment.type == DiffType.removed) {
        removed = segment.text;
        i++;
      }
      if (i < segments.length && segments[i].type == DiffType.inserted) {
        inserted = segments[i].text;
        i++;
      }
      final edit = _unlistedEdit(
        source,
        locator,
        gaps,
        boundaries,
        start: position,
        end: position + removed.length,
        inserted: inserted,
      );
      if (edit != null) extra.add(edit);
      position += removed.length;
    }
    return extra.isEmpty ? edits : [...edits, ...extra];
  }

  /// Turns the change of applied-text range [start, end) into [inserted]
  /// into an edit of [source], or `null` when the change touches a listed
  /// edit or cannot be located unambiguously. The original is widened by
  /// neighbouring tokens until [locate] would place it exactly here.
  static ProofreadEdit? _unlistedEdit(
    String source,
    _Locator locator,
    List<_Gap> gaps,
    List<int> boundaries, {
    required int start,
    required int end,
    required String inserted,
  }) {
    _Gap? gap;
    for (final candidate in gaps) {
      if (start >= candidate.appliedStart && end <= candidate.appliedEnd) {
        gap = candidate;
        break;
      }
    }
    if (gap == null) return null;
    final changeStart = gap.start + (start - gap.appliedStart);
    final changeEnd = changeStart + (end - start);
    var from = changeStart;
    var to = changeEnd;
    for (var attempt = 0; attempt < _maxWidening; attempt++) {
      if (to > from) {
        final original = source.substring(from, to);
        final location = locator.find(original);
        if (location != null && location.start == from && location.end == to) {
          locator.commit(location);
          return ProofreadEdit(
            original: original,
            replacement:
                source.substring(from, changeStart) +
                inserted +
                source.substring(changeEnd, to),
            category: otherCategory,
          );
        }
      }
      final left = from > gap.start
          ? math.max(_boundaryBefore(boundaries, from), gap.start)
          : null;
      final right = to < gap.end
          ? math.min(_boundaryAfter(boundaries, to), gap.end)
          : null;
      if (left != null && (attempt.isEven || right == null)) {
        from = left;
      } else if (right != null) {
        to = right;
      } else {
        return null;
      }
    }
    return null;
  }

  /// How many neighbouring tokens [_unlistedEdit] may add to an original.
  static const _maxWidening = 12;

  /// Start offsets of the tokens of [text], followed by its length.
  static List<int> _tokenBoundaries(String text) => [
    for (final match in _tokenPattern.allMatches(text)) match.start,
    text.length,
  ];

  /// Largest boundary below [offset] (0 when there is none).
  static int _boundaryBefore(List<int> boundaries, int offset) {
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (boundaries[mid] < offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low == 0 ? 0 : boundaries[low - 1];
  }

  /// Smallest boundary above [offset] (the last boundary when there is none).
  static int _boundaryAfter(List<int> boundaries, int offset) {
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (boundaries[mid] <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low == boundaries.length ? boundaries.last : boundaries[low];
  }

  /// Located edits as `(index, location)`, sorted by position.
  static List<(int, EditLocation)> _ordered(List<EditLocation?> locations) =>
      [
        for (var i = 0; i < locations.length; i++)
          if (locations[i] case final location?) (i, location),
      ]..sort((a, b) => a.$2.start.compareTo(b.$2.start));

  /// Inline diff of [source] with the [accepted] edits applied. Accepted
  /// edits are refined with a word-level diff of original vs replacement;
  /// rejected edits are shown unchanged. Segments carry their edit index.
  static List<DiffSegment> editSegments(
    String source,
    List<ProofreadEdit> edits,
    Set<int> accepted,
  ) {
    final segments = <DiffSegment>[];
    var cursor = 0;
    for (final (i, location) in _ordered(locate(source, edits))) {
      if (location.start > cursor) {
        segments.add(
          DiffSegment.unchanged(source.substring(cursor, location.start)),
        );
      }
      final edit = edits[i];
      if (accepted.contains(i)) {
        segments.addAll(
          wordDiff(edit.original, edit.replacement, editIndex: i),
        );
      } else {
        segments.add(DiffSegment.unchanged(edit.original, editIndex: i));
      }
      cursor = location.end;
    }
    if (cursor < source.length) {
      segments.add(DiffSegment.unchanged(source.substring(cursor)));
    }
    return _merge(segments);
  }

  /// Scripts written without spaces between words (Chinese, Japanese,
  /// Thai, Lao, Khmer, Myanmar): each character is its own token.
  static const _unspaced =
      r'\p{scx=Han}\p{scx=Hira}\p{scx=Kana}\p{scx=Thai}\p{scx=Lao}'
      r'\p{scx=Khmr}\p{scx=Mymr}';

  /// A letter, mark, digit or underscore of a script that uses spaces.
  static const _wordChar = '(?:(?![$_unspaced])[\\p{L}\\p{M}\\p{N}_])';

  static final _tokenPattern = RegExp(
    "[$_unspaced]\\p{M}*|$_wordChar+(?:['’]$_wordChar+)*|\\s+|.",
    unicode: true,
    dotAll: true,
  );

  static final _wordCharPattern = RegExp('^$_wordChar\$', unicode: true);
  static final _markPattern = RegExp(r'^\p{M}$', unicode: true);

  /// Whether a token boundary lies at [index] of [text]: not inside a word
  /// of a spaced script, before a combining mark or inside a surrogate pair.
  static bool _isBoundary(String text, int index) {
    if (index <= 0 || index >= text.length) return true;
    if (_isLowSurrogate(text.codeUnitAt(index)) &&
        _isHighSurrogate(text.codeUnitAt(index - 1))) {
      return false;
    }
    final after = _charAt(text, index);
    if (_markPattern.hasMatch(after)) return false;
    return !(_wordCharPattern.hasMatch(_charBefore(text, index)) &&
        _wordCharPattern.hasMatch(after));
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// The character (code point) starting at [index].
  static String _charAt(String text, int index) {
    final end =
        _isHighSurrogate(text.codeUnitAt(index)) &&
            index + 1 < text.length &&
            _isLowSurrogate(text.codeUnitAt(index + 1))
        ? index + 2
        : index + 1;
    return text.substring(index, end);
  }

  /// The character (code point) ending at [index].
  static String _charBefore(String text, int index) {
    final start =
        _isLowSurrogate(text.codeUnitAt(index - 1)) &&
            index >= 2 &&
            _isHighSurrogate(text.codeUnitAt(index - 2))
        ? index - 2
        : index - 1;
    return text.substring(start, index);
  }

  /// Splits [text] into words, whitespace runs and single other characters.
  /// Characters of scripts without spaces between words (Chinese, Japanese,
  /// Thai, ...) are one token each, together with their combining marks.
  static List<String> tokenize(String text) => [
    for (final match in _tokenPattern.allMatches(text)) match[0]!,
  ];

  /// Word-level diff of [before] -> [after] (Myers). Within a change, the
  /// removed text precedes the inserted text; whitespace-only gaps between
  /// two changes are folded into the change for readability.
  static List<DiffSegment> wordDiff(
    String before,
    String after, {
    int? editIndex,
  }) {
    if (before == after) {
      return [
        if (before.isNotEmpty)
          DiffSegment.unchanged(before, editIndex: editIndex),
      ];
    }
    final a = tokenize(before);
    final b = tokenize(after);

    var prefix = 0;
    while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < a.length - prefix &&
        suffix < b.length - prefix &&
        a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
      suffix++;
    }

    final ops = <(DiffType, String)>[
      for (final token in a.take(prefix)) (DiffType.unchanged, token),
      ..._myers(
        a.sublist(prefix, a.length - suffix),
        b.sublist(prefix, b.length - suffix),
      ),
      for (final token in a.skip(a.length - suffix))
        (DiffType.unchanged, token),
    ];
    return _merge(_group(ops, editIndex));
  }

  /// Turns token operations into segments: each change block (consecutive
  /// removals/insertions, plus whitespace-only gaps between them) becomes one
  /// removed and one inserted segment.
  static List<DiffSegment> _group(
    List<(DiffType, String)> ops,
    int? editIndex,
  ) {
    final segments = <DiffSegment>[];
    final removed = StringBuffer();
    final inserted = StringBuffer();
    var i = 0;

    void flushChange() {
      if (removed.isNotEmpty) {
        segments.add(
          DiffSegment.removed(removed.toString(), editIndex: editIndex),
        );
      }
      if (inserted.isNotEmpty) {
        segments.add(
          DiffSegment.inserted(inserted.toString(), editIndex: editIndex),
        );
      }
      removed.clear();
      inserted.clear();
    }

    while (i < ops.length) {
      final (type, token) = ops[i];
      switch (type) {
        case DiffType.removed:
          removed.write(token);
          i++;
        case DiffType.inserted:
          inserted.write(token);
          i++;
        case DiffType.unchanged:
          final inChange = removed.isNotEmpty || inserted.isNotEmpty;
          if (inChange && token.trim().isEmpty) {
            // Fold a whitespace gap into the change when another change
            // follows immediately.
            final next = i + 1 < ops.length ? ops[i + 1].$1 : null;
            if (next != null && next != DiffType.unchanged) {
              removed.write(token);
              inserted.write(token);
              i++;
              continue;
            }
          }
          flushChange();
          segments.add(DiffSegment.unchanged(token, editIndex: editIndex));
          i++;
      }
    }
    flushChange();
    return segments;
  }

  /// Joins adjacent segments of the same type and edit index.
  static List<DiffSegment> _merge(List<DiffSegment> segments) {
    final merged = <DiffSegment>[];
    for (final segment in segments) {
      if (segment.text.isEmpty) continue;
      final last = merged.isEmpty ? null : merged.last;
      if (last != null &&
          last.type == segment.type &&
          last.editIndex == segment.editIndex) {
        merged[merged.length - 1] = DiffSegment(
          last.type,
          last.text + segment.text,
          editIndex: last.editIndex,
        );
      } else {
        merged.add(segment);
      }
    }
    return merged;
  }

  /// Upper bound on the memory used by [_myers] (in 32-bit cells). The
  /// trace of an edit script with D changes takes (D + 1)² cells, so texts
  /// with up to ~2800 token changes are diffed exactly.
  static const maxTraceCells = 8000000;

  /// Myers' O(ND) shortest edit script over token lists.
  static List<(DiffType, String)> _myers(List<String> a, List<String> b) {
    final n = a.length;
    final m = b.length;
    List<(DiffType, String)> replaceAll() => [
      for (final token in a) (DiffType.removed, token),
      for (final token in b) (DiffType.inserted, token),
    ];
    if (n == 0 || m == 0) return replaceAll();
    final max = n + m;
    final offset = max;
    final v = Int32List(2 * max + 2);
    // trace[d] holds v[-d..d] as it was before step d (index k + d).
    final trace = <Int32List>[];
    var cells = 0;

    search:
    for (var d = 0; d <= max; d++) {
      cells += 2 * d + 1;
      // Too different to diff cheaply: show a whole replacement.
      if (cells > maxTraceCells) return replaceAll();
      trace.add(Int32List.fromList(v.sublist(offset - d, offset + d + 1)));
      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
          x = v[offset + k + 1];
        } else {
          x = v[offset + k - 1] + 1;
        }
        var y = x - k;
        while (x < n && y < m && a[x] == b[y]) {
          x++;
          y++;
        }
        v[offset + k] = x;
        if (x >= n && y >= m) break search;
      }
    }

    final reversed = <(DiffType, String)>[];
    var x = n;
    var y = m;
    for (var d = trace.length - 1; d >= 0; d--) {
      final vd = trace[d];
      final k = x - y;
      final int prevK;
      if (k == -d || (k != d && vd[k - 1 + d] < vd[k + 1 + d])) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      // Step 0 starts from the virtual point (0, -1).
      final prevX = d == 0 ? 0 : vd[prevK + d];
      final prevY = prevX - prevK;
      while (x > prevX && y > prevY) {
        reversed.add((DiffType.unchanged, a[x - 1]));
        x--;
        y--;
      }
      if (d > 0) {
        if (x == prevX) {
          reversed.add((DiffType.inserted, b[y - 1]));
          y--;
        } else {
          reversed.add((DiffType.removed, a[x - 1]));
          x--;
        }
      }
    }
    return reversed.reversed.toList();
  }
}

/// An unchanged stretch [start, end) of the source and its offset in the
/// text with every located edit applied.
final class _Gap {
  const new(this.start, this.end, this.appliedStart);

  final int start;
  final int end;
  final int appliedStart;

  int get appliedEnd => appliedStart + end - start;
}

/// Places edit originals in a source text (see [ProofreadDiff.locate]).
final class _Locator {
  new(this.source);

  final String source;

  /// Placed locations, sorted by start and never overlapping.
  final _placed = <EditLocation>[];
  var _cursor = 0;

  /// Where [original] would be placed next (without placing it).
  EditLocation? find(String original) {
    if (original.isEmpty) return null;
    return _first(original, _cursor, boundary: true) ??
        _first(original, 0, boundary: true) ??
        _first(original, _cursor, boundary: false) ??
        _first(original, 0, boundary: false);
  }

  /// Places [original] (see [find]) and returns its location.
  EditLocation? add(String original) {
    final location = find(original);
    if (location != null) commit(location);
    return location;
  }

  void commit(EditLocation location) {
    _placed.insert(_lowerBound(location.start), location);
    if (location.end > _cursor) _cursor = location.end;
  }

  EditLocation? _first(String original, int from, {required bool boundary}) {
    for (
      var start = source.indexOf(original, from);
      start >= 0;
      start = source.indexOf(original, start + 1)
    ) {
      final end = start + original.length;
      if (boundary &&
          !(ProofreadDiff._isBoundary(source, start) &&
              ProofreadDiff._isBoundary(source, end))) {
        continue;
      }
      if (_overlaps(start, end)) continue;
      return EditLocation(start, end);
    }
    return null;
  }

  /// Index of the first placed location starting at or after [start].
  int _lowerBound(int start) {
    var low = 0;
    var high = _placed.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_placed[mid].start < start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  bool _overlaps(int start, int end) {
    final index = _lowerBound(start);
    return (index < _placed.length && _placed[index].start < end) ||
        (index > 0 && _placed[index - 1].end > start);
  }
}
