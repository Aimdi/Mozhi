import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// Kind of a [DiffSegment].
enum DiffType { unchanged, removed, inserted }

/// A run of text in an inline diff between the proofread input and the
/// corrected output.
class DiffSegment extends Equatable {
  const DiffSegment(this.type, this.text, {this.editIndex});

  const DiffSegment.unchanged(String text, {int? editIndex})
    : this(DiffType.unchanged, text, editIndex: editIndex);

  const DiffSegment.removed(String text, {int? editIndex})
    : this(DiffType.removed, text, editIndex: editIndex);

  const DiffSegment.inserted(String text, {int? editIndex})
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
  const EditLocation(this.start, this.end);

  final int start;
  final int end;

  @override
  List<Object?> get props => [start, end];
}

/// Pure helpers that apply proofreading edits and compute inline diffs.
abstract final class ProofreadDiff {
  /// Locates [edits] in [source], in order.
  ///
  /// Each edit matches the first occurrence of its `original` at or after
  /// the end of the previously located edit. Edits whose original is empty
  /// or cannot be found (e.g. overlapping or out-of-order edits) are `null`
  /// and are skipped by [apply] and [editSegments]. Locations do not depend
  /// on which edits are accepted, so toggling one edit never moves another.
  static List<EditLocation?> locate(String source, List<ProofreadEdit> edits) {
    var cursor = 0;
    final locations = <EditLocation?>[];
    for (final edit in edits) {
      final original = edit.original;
      final start = original.isEmpty ? -1 : source.indexOf(original, cursor);
      if (start < 0) {
        locations.add(null);
        continue;
      }
      final end = start + original.length;
      locations.add(EditLocation(start, end));
      cursor = end;
    }
    return locations;
  }

  /// Applies the [accepted] edits (by index) to [source].
  static String apply(
    String source,
    List<ProofreadEdit> edits,
    Set<int> accepted,
  ) {
    final locations = locate(source, edits);
    final buffer = StringBuffer();
    var cursor = 0;
    for (var i = 0; i < edits.length; i++) {
      final location = locations[i];
      if (location == null || !accepted.contains(i)) continue;
      buffer
        ..write(source.substring(cursor, location.start))
        ..write(edits[i].replacement);
      cursor = location.end;
    }
    buffer.write(source.substring(cursor));
    return buffer.toString();
  }

  /// Inline diff of [source] with the [accepted] edits applied. Accepted
  /// edits are refined with a word-level diff of original vs replacement;
  /// rejected edits are shown unchanged. Segments carry their edit index.
  static List<DiffSegment> editSegments(
    String source,
    List<ProofreadEdit> edits,
    Set<int> accepted,
  ) {
    final locations = locate(source, edits);
    final segments = <DiffSegment>[];
    var cursor = 0;
    for (var i = 0; i < edits.length; i++) {
      final location = locations[i];
      if (location == null) continue;
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

  static final _tokenPattern = RegExp(
    r"[\p{L}\p{M}\p{N}_]+(?:['’][\p{L}\p{M}\p{N}_]+)*|\s+|.",
    unicode: true,
    dotAll: true,
  );

  /// Splits [text] into words, whitespace runs and single other characters.
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

  /// Upper bound on the memory used by [_myers] (in 32-bit cells).
  static const maxTraceCells = 8000000;

  /// Myers' O(ND) shortest edit script over token lists.
  static List<(DiffType, String)> _myers(List<String> a, List<String> b) {
    final n = a.length;
    final m = b.length;
    if (n == 0 || m == 0) {
      return [
        for (final token in a) (DiffType.removed, token),
        for (final token in b) (DiffType.inserted, token),
      ];
    }
    final max = n + m;
    final offset = max;
    final v = Int32List(2 * max + 2);
    final trace = <Int32List>[];

    search:
    for (var d = 0; d <= max; d++) {
      if ((d + 1) * v.length > maxTraceCells) {
        // Too different to diff cheaply: show a whole replacement.
        return [
          for (final token in a) (DiffType.removed, token),
          for (final token in b) (DiffType.inserted, token),
        ];
      }
      trace.add(Int32List.fromList(v));
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
      if (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      final prevX = vd[offset + prevK];
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
