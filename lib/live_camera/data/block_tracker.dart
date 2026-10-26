import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:mozhi/image_translate/models/text_layout.dart';
import 'package:mozhi/live_camera/models/live_block.dart';

/// Follows the paragraphs text recognition finds in one camera frame after
/// another ([track]), so the overlay holds still and only new or changed
/// text is translated:
///
/// * A paragraph found again (its box overlaps the block's and its text is
///   alike, or the text is nearly the same a little further on: the camera
///   moved) keeps the block, its id and its translation. A box that moved
///   only a little ([holdOverlap]) stays where it was; the colours stay.
/// * Its text is replaced only when it really changed: a reading at least
///   [jitterSimilarity] alike is recognition noise and keeps the text the
///   block has (and its translation), unless it is clearly surer
///   (confidence [betterConfidence] points higher).
/// * A block not found keeps its place for [maxMissed] frames.
/// * Every other paragraph becomes a new block.
///
/// Blocks are returned top to bottom, left to right.
class BlockTracker {
  BlockTracker({
    this.maxMissed = 2,
    this.holdOverlap = 0.6,
    this.jitterSimilarity = 0.85,
    this.betterConfidence = 10,
  });

  final int maxMissed;
  final double holdOverlap;
  final double jitterSimilarity;
  final int betterConfidence;

  int _nextId = 1;

  /// The blocks after [found] (the paragraphs of a frame of [frame] size)
  /// were matched with [previous].
  List<LiveBlock> track(
    List<LiveBlock> previous,
    List<TextParagraph> found, {
    required Size frame,
  }) {
    final diagonal = math.sqrt(
      frame.width * frame.width + frame.height * frame.height,
    );
    final candidates = <_Candidate>[];
    final normalizedFound = [for (final p in found) normalizeLiveText(p.text)];
    for (var i = 0; i < previous.length; i++) {
      final block = previous[i];
      final text = normalizeLiveText(block.text);
      for (var j = 0; j < found.length; j++) {
        final overlap = boxOverlap(block.box, found[j].box);
        final similarity = textSimilarity(text, normalizedFound[j]);
        final distance = (block.box.center - found[j].box.center).distance;
        final near = diagonal > 0 && distance <= diagonal * 0.2;
        final matches =
            (overlap >= 0.3 && similarity >= 0.3) ||
            (overlap > 0 && similarity >= 0.6) ||
            (near && similarity >= 0.8);
        if (matches) {
          candidates.add(_Candidate(i, j, overlap, similarity));
        }
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final matchedBlocks = <int, _Candidate>{};
    final matchedFound = <int>{};
    for (final candidate in candidates) {
      if (matchedBlocks.containsKey(candidate.block) ||
          matchedFound.contains(candidate.found)) {
        continue;
      }
      matchedBlocks[candidate.block] = candidate;
      matchedFound.add(candidate.found);
    }

    final next = <LiveBlock>[];
    for (var i = 0; i < previous.length; i++) {
      final block = previous[i];
      final match = matchedBlocks[i];
      if (match == null) {
        if (block.missed < maxMissed) {
          next.add(block.copyWith(missed: block.missed + 1));
        }
        continue;
      }
      next.add(_follow(block, found[match.found], match));
    }
    for (var j = 0; j < found.length; j++) {
      if (matchedFound.contains(j)) continue;
      next.add(LiveBlock(id: _nextId++, paragraph: found[j]));
    }
    next.sort(_readingOrder);
    return next;
  }

  LiveBlock _follow(LiveBlock block, TextParagraph found, _Candidate match) {
    final old = block.paragraph;
    final same = normalizeLiveText(old.text) == normalizeLiveText(found.text);
    final surer =
        (found.confidence ?? 0) >= (old.confidence ?? 0) + betterConfidence;
    final keepText = same || (match.similarity >= jitterSimilarity && !surer);
    final box = match.overlap >= holdOverlap ? old.box : found.box;
    final paragraph = keepText
        ? TextParagraph(
            text: old.text,
            box: box,
            lineCount: old.lineCount,
            alignment: old.alignment,
            isRightToLeft: old.isRightToLeft,
            background: old.background ?? found.background,
            foreground: old.foreground ?? found.foreground,
            confidence: old.confidence,
          )
        : TextParagraph(
            text: found.text,
            box: box,
            lineCount: found.lineCount,
            alignment: found.alignment,
            isRightToLeft: found.isRightToLeft,
            background: found.background ?? old.background,
            foreground: found.foreground ?? old.foreground,
            confidence: found.confidence,
          );
    return block.copyWith(
      paragraph: paragraph,
      seen: block.seen + 1,
      missed: 0,
    );
  }

  static int _readingOrder(LiveBlock a, LiveBlock b) {
    final top = a.box.top.compareTo(b.box.top);
    if (top != 0) return top;
    return a.box.left.compareTo(b.box.left);
  }
}

class _Candidate {
  _Candidate(this.block, this.found, this.overlap, this.similarity);

  final int block;
  final int found;
  final double overlap;
  final double similarity;

  double get score => overlap + similarity;
}

/// [text] for comparisons: lower case, runs of white space as one space,
/// trimmed.
String normalizeLiveText(String text) =>
    text.toLowerCase().replaceAll(_whitespace, ' ').trim();

final _whitespace = RegExp(r'\s+');

/// Intersection over union of [a] and [b] (0 to 1).
double boxOverlap(Rect a, Rect b) {
  final intersection = a.intersect(b);
  if (intersection.width <= 0 || intersection.height <= 0) return 0;
  final shared = intersection.width * intersection.height;
  final union = a.width * a.height + b.width * b.height - shared;
  return union <= 0 ? 0 : shared / union;
}

/// How alike two (normalized) texts are, 0 to 1: the Sørensen–Dice
/// coefficient of their character pairs (linear in their length).
double textSimilarity(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  final first = a.runes.toList();
  final second = b.runes.toList();
  if (first.length < 2 || second.length < 2) return 0;
  final pairs = <int, int>{};
  for (var i = 0; i < first.length - 1; i++) {
    final key = first[i] * 0x110000 + first[i + 1];
    pairs[key] = (pairs[key] ?? 0) + 1;
  }
  var shared = 0;
  for (var i = 0; i < second.length - 1; i++) {
    final key = second[i] * 0x110000 + second[i + 1];
    final count = pairs[key] ?? 0;
    if (count > 0) {
      pairs[key] = count - 1;
      shared++;
    }
  }
  return 2 * shared / (first.length - 1 + second.length - 1);
}
