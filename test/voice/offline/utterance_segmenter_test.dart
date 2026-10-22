import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/voice/voice.dart';

/// 32 ms windows.
const _frame = Duration(microseconds: 32000);

Float32List window(double value) =>
    Float32List(speechFrameSize)..fillRange(0, speechFrameSize, value);

void main() {
  late UtteranceSegmenter segmenter;
  late List<SpeechSegment> segments;

  setUp(() {
    segmenter = UtteranceSegmenter();
    segments = [];
  });

  /// Feeds [count] windows of probability [p] (their samples are [p] too,
  /// so a segment shows where its audio came from).
  void feed(int count, double p) {
    for (var i = 0; i < count; i++) {
      if (segmenter.add(window(p), p) case final segment?) {
        segments.add(segment);
      }
    }
  }

  test('silence is no phrase', () {
    feed(100, 0.1);
    expect(segments, isEmpty);
    expect(segmenter.heardSpeech, isFalse);
    expect(segmenter.silenceAfterSpeech, Duration.zero);
    expect(segmenter.recorded, _frame * 100);
    expect(segmenter.inPhrase, isFalse);
    expect(segmenter.flush(), isNull);
  });

  test('cuts a phrase after the pause, with padding around it', () {
    feed(20, 0.1); // 640 ms of silence
    feed(30, 0.9); // 960 ms of speech
    expect(segmenter.inPhrase, isTrue);
    expect(segmenter.heardSpeech, isTrue);
    feed(12, 0.1); // 384 ms: not yet a pause
    expect(segments, isEmpty);
    expect(segmenter.silenceAfterSpeech, _frame * 12);
    feed(1, 0.1); // 416 ms
    final segment = segments.single;
    expect(segment.index, 0);
    // 7 windows (224 ms >= 200 ms) of padding on each side.
    expect(segment.start, _frame * 13);
    expect(segment.end, _frame * 57);
    expect(segment.duration, _frame * 44);
    expect(segment.samples, hasLength(44 * speechFrameSize));
    expect(segment.samples.first, closeTo(0.1, 1e-6));
    expect(segment.samples[7 * speechFrameSize], closeTo(0.9, 1e-6));
    expect(segment.samples.last, closeTo(0.1, 1e-6));
    expect(segmenter.inPhrase, isFalse);
  });

  test('numbers phrases and keeps the time line', () {
    feed(10, 0.9);
    feed(13, 0.1);
    feed(10, 0.9);
    feed(13, 0.1);
    expect(segments.map((s) => s.index), [0, 1]);
    // The first starts at once (no silence before it).
    expect(segments.first.start, Duration.zero);
    // The silence between them: 7 windows of padding for the first, the
    // other 6 before the second.
    expect(segments.first.end, _frame * 17);
    expect(segments.last.start, _frame * 17);
    expect(segments.last.end, _frame * 40);
  });

  test('stays in speech until the probability drops below the '
      'release threshold', () {
    feed(10, 0.9);
    feed(20, 0.4); // above 0.35: still speech
    expect(segments, isEmpty);
    expect(segmenter.silenceAfterSpeech, Duration.zero);
    feed(13, 0.2);
    expect(segments.single.duration, _frame * 37);
    // ...but 0.4 does not start a phrase.
    feed(30, 0.4);
    expect(segmenter.inPhrase, isFalse);
  });

  test('drops blips shorter than minSpeech', () {
    feed(4, 0.9); // 128 ms < 160 ms
    feed(13, 0.1);
    expect(segments, isEmpty);
    // Still heard (it was speech-like), so a pause can follow it.
    expect(segmenter.heardSpeech, isTrue);
    feed(5, 0.9);
    feed(13, 0.1);
    expect(segments, hasLength(1));
    expect(segments.single.index, 0);
  });

  test('cuts long phrases at the quietest window', () {
    segmenter = UtteranceSegmenter(
      maxSegment: const Duration(seconds: 2),
      cutSearch: const Duration(milliseconds: 500),
    );
    // 63 windows of speech, the quietest at window 55.
    feed(55, 0.9);
    feed(1, 0.6);
    feed(7, 0.9);
    final first = segments.single;
    expect(first.end, _frame * 56);
    expect(segmenter.inPhrase, isTrue);
    feed(13, 0.1);
    expect(segments, hasLength(2));
    expect(segments.last.start, _frame * 56);
    expect(segments.last.end, _frame * 70);
  });

  test('a long phrase without a quieter window is cut at the limit', () {
    segmenter = UtteranceSegmenter(
      maxSegment: const Duration(seconds: 1),
      cutSearch: const Duration(milliseconds: 200),
    );
    feed(32, 0.9);
    expect(segments.single.end, _frame * 32);
    expect(segmenter.inPhrase, isFalse);
    feed(5, 0.9);
    expect(segmenter.flush()?.start, _frame * 32);
  });

  test('flush ends the phrase in progress', () {
    feed(10, 0.9);
    feed(20, 0.1);
    feed(10, 0.9);
    feed(10, 0.1); // 320 ms: not a pause yet
    final last = segmenter.flush()!;
    expect(last.index, 1);
    // 7 windows of padding before it; trailing silence beyond the
    // padding is left out.
    expect(last.start, _frame * 23);
    expect(last.end, _frame * 47);
    expect(segmenter.flush(), isNull);
    // A blip at the end is dropped too.
    feed(2, 0.9);
    expect(segmenter.flush(), isNull);
  });

  test('segments compare by position and length', () {
    final a = SpeechSegment(
      index: 0,
      samples: Float32List(4),
      start: Duration.zero,
      end: const Duration(seconds: 1),
    );
    expect(
      a,
      SpeechSegment(
        index: 0,
        samples: Float32List(4),
        start: Duration.zero,
        end: const Duration(seconds: 1),
      ),
    );
  });
}
