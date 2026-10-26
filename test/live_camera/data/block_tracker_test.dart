import 'dart:ui' show Color, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/models/text_layout.dart';
import 'package:mozhi/live_camera/data/block_tracker.dart';
import 'package:mozhi/live_camera/models/live_block.dart';

const _frame = Size(720, 1280);

TextParagraph _p(
  String text, {
  Rect box = const Rect.fromLTWH(100, 100, 300, 40),
  int? confidence = 80,
  Color? background,
}) => TextParagraph(
  text: text,
  box: box,
  confidence: confidence,
  background: background,
);

void main() {
  late BlockTracker tracker;

  setUp(() => tracker = BlockTracker());

  List<LiveBlock> track(List<LiveBlock> previous, List<TextParagraph> found) =>
      tracker.track(previous, found, frame: _frame);

  group('BlockTracker', () {
    test('new paragraphs become blocks with ids, top to bottom', () {
      final blocks = track(const [], [
        _p('Second', box: const Rect.fromLTWH(10, 300, 100, 20)),
        _p('First', box: const Rect.fromLTWH(200, 10, 100, 20)),
        _p('Also first', box: const Rect.fromLTWH(10, 10, 100, 20)),
      ]);
      expect(blocks.map((block) => block.text), [
        'Also first',
        'First',
        'Second',
      ]);
      expect(blocks.map((block) => block.id).toSet(), hasLength(3));
      expect(blocks.every((block) => block.seen == 1), isTrue);
    });

    test('a paragraph found again keeps its block, box and colours', () {
      const white = Color(0xFFFFFFFF);
      final first = track(const [], [_p('Platform 3', background: white)]);
      final translated = [first.single.translated('Gleis 3')];

      final next = track(translated, [
        _p(
          'Platform 3',
          box: const Rect.fromLTWH(104, 102, 300, 40),
          background: const Color(0xFF000000),
        ),
      ]);

      final block = next.single;
      expect(block.id, first.single.id);
      expect(block.box, first.single.box);
      expect(block.paragraph.background, white);
      expect(block.translation, 'Gleis 3');
      expect(block.needsTranslation, isFalse);
      expect(block.seen, 2);
    });

    test('a box that moved further follows the text', () {
      final first = track(const [], [_p('Platform 3')]);
      const moved = Rect.fromLTWH(220, 120, 300, 40);
      final next = track(first, [_p('Platform 3', box: moved)]);
      expect(next.single.id, first.single.id);
      expect(next.single.box, moved);
    });

    test('the same text elsewhere nearby is the same block', () {
      final first = track(const [], [_p('Departures to Paris')]);
      const far = Rect.fromLTWH(100, 260, 300, 40);
      final next = track(first, [_p('Departures to Paris', box: far)]);
      expect(next.single.id, first.single.id);
      expect(next.single.box, far);
    });

    test('recognition noise keeps the text and its translation', () {
      final first = track(const [], [_p('Platform three')]);
      final translated = [first.single.translated('Gleis drei')];
      final next = track(translated, [_p('Platfonn three')]);
      expect(next.single.text, 'Platform three');
      expect(next.single.needsTranslation, isFalse);
    });

    test('a clearly surer reading replaces the text', () {
      final first = track(const [], [_p('Platfonn three', confidence: 50)]);
      final next = track(first, [_p('Platform three', confidence: 90)]);
      expect(next.single.id, first.single.id);
      expect(next.single.text, 'Platform three');
      expect(next.single.paragraph.confidence, 90);
    });

    test('changed text in the same place is the block, to translate again', () {
      final first = track(const [], [_p('Open')]);
      final translated = [first.single.translated('Offen')];
      final next = track(translated, [_p('Closed today')]);
      final block = next.single;
      expect(block.id, first.single.id);
      expect(block.text, 'Closed today');
      expect(block.needsTranslation, isTrue);
      // The old translation shows until the new one comes.
      expect(block.translation, 'Offen');
    });

    test('a block not found stays for a few frames', () {
      var blocks = track(const [], [_p('Exit')]);
      final id = blocks.single.id;
      for (var missed = 1; missed <= 2; missed++) {
        blocks = track(blocks, const []);
        expect(blocks.single.id, id);
        expect(blocks.single.missed, missed);
      }
      expect(track(blocks, const []), isEmpty);
    });

    test('found again, a missed block counts from zero', () {
      var blocks = track(const [], [_p('Exit')]);
      blocks = track(blocks, const []);
      blocks = track(blocks, [_p('Exit')]);
      expect(blocks.single.missed, 0);
      expect(blocks.single.seen, 2);
    });

    test('each paragraph matches one block, the best one', () {
      final first = track(const [], [
        _p('Arrivals', box: const Rect.fromLTWH(0, 0, 200, 40)),
        _p('Departures', box: const Rect.fromLTWH(0, 200, 200, 40)),
      ]);
      final next = track(first, [
        _p('Departures', box: const Rect.fromLTWH(0, 205, 200, 40)),
        _p('Arrivals', box: const Rect.fromLTWH(0, 3, 200, 40)),
        _p('Lost luggage', box: const Rect.fromLTWH(0, 600, 200, 40)),
      ]);
      expect(next.map((block) => block.text), [
        'Arrivals',
        'Departures',
        'Lost luggage',
      ]);
      expect(next[0].id, first[0].id);
      expect(next[1].id, first[1].id);
      expect(next[2].id, isNot(anyOf(first[0].id, first[1].id)));
    });

    test('unrelated text far away is a new block', () {
      final first = track(const [], [_p('Arrivals')]);
      final next = track(first, [
        _p('Lost luggage', box: const Rect.fromLTWH(100, 900, 300, 40)),
      ]);
      expect(next, hasLength(2));
      expect(next.first.missed, 1);
    });
  });

  group('boxOverlap', () {
    test('is intersection over union', () {
      const a = Rect.fromLTWH(0, 0, 10, 10);
      expect(boxOverlap(a, a), 1);
      expect(
        boxOverlap(a, const Rect.fromLTWH(5, 0, 10, 10)),
        closeTo(1 / 3, 1e-9),
      );
      expect(boxOverlap(a, const Rect.fromLTWH(20, 20, 5, 5)), 0);
      expect(boxOverlap(Rect.zero, Rect.zero), 0);
    });
  });

  group('textSimilarity', () {
    test('compares character pairs', () {
      expect(textSimilarity('night', 'night'), 1);
      expect(textSimilarity('night', 'nacht'), closeTo(0.25, 1e-9));
      expect(textSimilarity('', 'a'), 0);
      expect(textSimilarity('a', 'b'), 0);
      expect(textSimilarity('aa', 'aaa'), closeTo(2 / 3, 1e-9));
    });
  });

  group('editDistance', () {
    test('counts insertions, deletions and substitutions', () {
      expect(editDistance('kitten', 'sitting'), 3);
      expect(editDistance('', 'abc'), 3);
      expect(editDistance('same', 'same'), 0);
    });

    test('stops above the limit', () {
      expect(editDistance('kitten', 'sitting', limit: 1), 2);
      expect(editDistance('a', 'abcdef', limit: 2), 3);
    });
  });

  test('normalizeLiveText', () {
    expect(normalizeLiveText('  Hello\n  World '), 'hello world');
  });
}
