import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/voice/voice.dart';

void main() {
  const entries = [
    TranscriptEntry(
      id: 0,
      start: Duration(seconds: 2, milliseconds: 40),
      end: Duration(seconds: 5, milliseconds: 500),
      text: 'Welcome to the museum.',
      translation: 'Willkommen im Museum.',
      translationStatus: TranscriptTranslationStatus.done,
    ),
    TranscriptEntry(
      id: 1,
      start: Duration(seconds: 6),
      end: Duration(seconds: 9),
      status: PhraseStatus.skipped,
    ),
    TranscriptEntry(
      id: 2,
      start: Duration(minutes: 61, seconds: 1),
      end: Duration(minutes: 61, seconds: 4, milliseconds: 7),
      text: 'This way, please.',
      translation: 'Hier',
      translationStatus: TranscriptTranslationStatus.translating,
    ),
  ];

  test('text: a paragraph per phrase with its time and translation', () {
    expect(
      TranscriptExport.text(entries, skipped: '(skipped)', title: 'Tour'),
      'Tour\n\n'
      '[0:02] Welcome to the museum.\nWillkommen im Museum.\n\n'
      '[0:06] (skipped)\n\n'
      '[1:01:01] This way, please.\n',
    );
    expect(TranscriptExport.text(const [], skipped: '-'), '\n');
  });

  test('plain text and translations for the history', () {
    expect(
      TranscriptExport.plain(entries),
      'Welcome to the museum.\n\nThis way, please.',
    );
    expect(TranscriptExport.plainTranslation(entries), 'Willkommen im Museum.');
  });

  test('SubRip: numbered cues of the transcribed phrases', () {
    expect(
      TranscriptExport.srt(entries),
      '1\n00:00:02,040 --> 00:00:05,500\n'
      'Welcome to the museum.\nWillkommen im Museum.\n\n'
      '2\n01:01:01,000 --> 01:01:04,007\nThis way, please.\n',
    );
    expect(TranscriptExport.srt(const []), isEmpty);
    expect(
      TranscriptExport.srtTime(const Duration(seconds: -1)),
      '00:00:00,000',
    );
  });

  test('bytes are UTF-8; gaps are noticed', () {
    expect(utf8.decode(TranscriptExport.bytes('Grüße')), 'Grüße');
    expect(TranscriptExport.hasGaps(entries), isTrue);
    expect(TranscriptExport.hasGaps(entries.sublist(0, 1)), isFalse);
  });

  test('entries compare by value and copy', () {
    final entry = entries.first;
    expect(entry.hasText, isTrue);
    expect(entry.isTranslated, isTrue);
    expect(entries[1].hasText, isFalse);
    final copy = entry.copyWith(
      translation: 'Hallo',
      translationStatus: () => null,
      translationError: () => 'x',
      engineId: () => 'mozhi:deepl',
      engineName: () => 'DeepL',
    );
    expect(copy.translation, 'Hallo');
    expect(copy.translationStatus, isNull);
    expect(copy.engineName, 'DeepL');
    expect(copy, isNot(entry));
    expect(entry.copyWith(), entry);
  });
}
