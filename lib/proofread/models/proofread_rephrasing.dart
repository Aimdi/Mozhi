import 'package:equatable/equatable.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';

/// A sentence of the corrected text that the user replaced with one of its
/// alternative phrasings (DeepL Write's "click a sentence").
///
/// [start] and [end] are offsets into the text the rephrasing was made for
/// (`ProofreadState.outputText`: the input with the accepted edits), which
/// holds [original] there; they are always exactly one of its sentences
/// ([SentenceSegmenter.split]).
class ProofreadRephrasing extends Equatable {
  const new({
    required this.start,
    required this.end,
    required this.original,
    required this.replacement,
  });

  final int start;
  final int end;

  /// The sentence as the corrected text has it.
  final String original;

  /// What the user chose instead.
  final String replacement;

  SentenceRange get sentence => SentenceRange(start, end);

  @override
  List<Object?> get props => [start, end, original, replacement];
}

/// Kind of an [OutputSegment].
enum OutputSegmentType { unchanged, removed, inserted, rephrased }

/// A run of the result text as it is shown: a diff segment (or part of
/// one) of a sentence, or a rephrased sentence.
class OutputSegment extends Equatable {
  const new(this.type, this.text, {this.editIndex, this.sentence});

  final OutputSegmentType type;
  final String text;

  /// Index of the edit the segment belongs to, when known.
  final int? editIndex;

  /// Index of the sentence (in [SentenceSegmenter.split] of the corrected
  /// text) the segment belongs to; null for the whitespace between them.
  final int? sentence;

  @override
  List<Object?> get props => [type, text, editIndex, sentence];

  @override
  String toString() =>
      'OutputSegment(${type.name}, "$text", $editIndex, $sentence)';
}

/// Pure helpers for the user's rephrasings, applied on top of the
/// corrected text (the input with the accepted edits).
///
/// The model: the edits produce the corrected text; its sentences
/// ([SentenceSegmenter.split]) are what the user can tap; each
/// [ProofreadRephrasing] replaces exactly one of them. The text the user
/// gets ([apply]) is the corrected text with the rephrasings. When the
/// corrected text changes (an edit is accepted or rejected), [remap] keeps
/// the rephrasings of the sentences the change did not touch; a new
/// proofread drops them all.
abstract final class ProofreadRephrasings {
  /// [base] with [rephrasings] applied. Rephrasings that do not match
  /// [base] (out of range, overlapping an earlier one, or with another
  /// [ProofreadRephrasing.original]) are ignored.
  static String apply(String base, List<ProofreadRephrasing> rephrasings) {
    if (rephrasings.isEmpty) return base;
    final buffer = StringBuffer();
    var position = 0;
    for (final rephrasing in _valid(base, rephrasings)) {
      buffer
        ..write(base.substring(position, rephrasing.start))
        ..write(rephrasing.replacement);
      position = rephrasing.end;
    }
    buffer.write(base.substring(position));
    return buffer.toString();
  }

  /// [rephrasings] that match [base], sorted, without overlaps.
  static List<ProofreadRephrasing> _valid(
    String base,
    List<ProofreadRephrasing> rephrasings,
  ) {
    final sorted = [...rephrasings]..sort((a, b) => a.start - b.start);
    final valid = <ProofreadRephrasing>[];
    var position = 0;
    for (final rephrasing in sorted) {
      if (rephrasing.start < position ||
          rephrasing.end > base.length ||
          rephrasing.start > rephrasing.end ||
          base.substring(rephrasing.start, rephrasing.end) !=
              rephrasing.original) {
        continue;
      }
      valid.add(rephrasing);
      position = rephrasing.end;
    }
    return valid;
  }

  /// [rephrasings] with [sentence] of [base] replaced by [replacement]
  /// (replacing an earlier rephrasing of it); a [replacement] equal to the
  /// sentence itself, or blank, removes its rephrasing instead.
  ///
  /// Returns [rephrasings] unchanged when [sentence] is no sentence of
  /// [base].
  static List<ProofreadRephrasing> replace(
    String base,
    List<ProofreadRephrasing> rephrasings,
    SentenceRange sentence,
    String replacement,
  ) {
    if (!SentenceSegmenter.split(base).contains(sentence)) return rephrasings;
    final original = sentence.of(base);
    final kept = [
      for (final rephrasing in rephrasings)
        if (rephrasing.sentence != sentence) rephrasing,
    ];
    final text = replacement.trim();
    if (text.isEmpty || text == original) return kept;
    return [
      ...kept,
      ProofreadRephrasing(
        start: sentence.start,
        end: sentence.end,
        original: original,
        replacement: text,
      ),
    ]..sort((a, b) => a.start - b.start);
  }

  /// [rephrasings] of [oldBase] moved to [newBase]: those in the common
  /// start or end of both texts are kept (shifted by the change in length)
  /// when they are still exactly a sentence of [newBase]; the others are
  /// dropped.
  static List<ProofreadRephrasing> remap(
    String oldBase,
    String newBase,
    List<ProofreadRephrasing> rephrasings,
  ) {
    if (rephrasings.isEmpty || oldBase == newBase) return rephrasings;
    final shortest = oldBase.length < newBase.length
        ? oldBase.length
        : newBase.length;
    var prefix = 0;
    while (prefix < shortest &&
        oldBase.codeUnitAt(prefix) == newBase.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shortest - prefix &&
        oldBase.codeUnitAt(oldBase.length - 1 - suffix) ==
            newBase.codeUnitAt(newBase.length - 1 - suffix)) {
      suffix++;
    }
    final changeEnd = oldBase.length - suffix;
    final delta = newBase.length - oldBase.length;
    final sentences = SentenceSegmenter.split(newBase).toSet();
    final moved = <ProofreadRephrasing>[];
    for (final rephrasing in _valid(oldBase, rephrasings)) {
      final int shift;
      if (rephrasing.end <= prefix) {
        shift = 0;
      } else if (rephrasing.start >= changeEnd) {
        shift = delta;
      } else {
        continue;
      }
      final next = SentenceRange(
        rephrasing.start + shift,
        rephrasing.end + shift,
      );
      if (!sentences.contains(next)) continue;
      moved.add(
        ProofreadRephrasing(
          start: next.start,
          end: next.end,
          original: rephrasing.original,
          replacement: rephrasing.replacement,
        ),
      );
    }
    return moved;
  }

  /// [segments] (a diff whose unchanged and inserted texts make up [base])
  /// split at the [sentences] of [base], each piece tagged with its
  /// sentence, and the rephrased sentences shown as their replacement (one
  /// [OutputSegmentType.rephrased] segment each, in place of the pieces and
  /// removals inside them).
  ///
  /// When [segments] do not make up [base], [base] is shown as unchanged
  /// text.
  static List<OutputSegment> overlay(
    List<DiffSegment> segments,
    String base,
    List<SentenceRange> sentences,
    List<ProofreadRephrasing> rephrasings,
  ) {
    final shown = segments
        .where((s) => s.type != DiffType.removed)
        .map((s) => s.text)
        .join();
    final source = shown == base ? segments : [DiffSegment.unchanged(base)];
    final replaced = <int, String>{
      for (final rephrasing in _valid(base, rephrasings))
        if (sentences.indexOf(rephrasing.sentence) case final index
            when index >= 0)
          index: rephrasing.replacement,
    };
    final output = <OutputSegment>[];
    final emitted = <int>{};
    var position = 0;
    var sentence = 0;

    /// The sentence at [offset] (moving [sentence] forward), or null.
    int? sentenceAt(int offset, {bool removal = false}) {
      while (sentence < sentences.length && sentences[sentence].end <= offset) {
        // A removal at the very end of a sentence still belongs to it.
        if (removal && sentences[sentence].end == offset) return sentence;
        sentence++;
      }
      if (sentence < sentences.length &&
          (sentences[sentence].contains(offset) ||
              (removal && sentences[sentence].start == offset))) {
        return sentence;
      }
      return null;
    }

    void add(OutputSegmentType type, String text, int? editIndex, int? index) {
      if (text.isEmpty) return;
      if (index != null && replaced.containsKey(index)) {
        if (emitted.add(index)) {
          output.add(
            OutputSegment(
              OutputSegmentType.rephrased,
              replaced[index]!,
              sentence: index,
            ),
          );
        }
        return;
      }
      output.add(
        OutputSegment(type, text, editIndex: editIndex, sentence: index),
      );
    }

    for (final segment in source) {
      final type = switch (segment.type) {
        DiffType.unchanged => OutputSegmentType.unchanged,
        DiffType.removed => OutputSegmentType.removed,
        DiffType.inserted => OutputSegmentType.inserted,
      };
      if (segment.type == DiffType.removed) {
        add(
          type,
          segment.text,
          segment.editIndex,
          sentenceAt(position, removal: true),
        );
        continue;
      }
      // Split at the sentence boundaries inside the segment.
      final end = position + segment.text.length;
      var offset = position;
      while (offset < end) {
        final index = sentenceAt(offset);
        final int pieceEnd;
        if (index != null) {
          pieceEnd = sentences[index].end < end ? sentences[index].end : end;
        } else {
          final nextStart = sentence < sentences.length
              ? sentences[sentence].start
              : end;
          pieceEnd = nextStart < end && nextStart > offset ? nextStart : end;
        }
        add(type, base.substring(offset, pieceEnd), segment.editIndex, index);
        offset = pieceEnd;
      }
      position = end;
    }
    return output;
  }
}
