import 'dart:convert';
import 'dart:typed_data';

import 'package:mozhi/transcribe/data/transcriber.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';

/// A transcript as plain text and as SubRip subtitles (`.srt`), with the
/// translations when there are some. Nothing here leaves the device.
abstract final class TranscriptExport {
  /// MIME type of [text].
  static const textMimeType = 'text/plain';

  /// MIME type of [srt].
  static const srtMimeType = 'application/x-subrip';

  /// The transcript as text: [title], then a paragraph per entry starting
  /// with its time (`[1:05]`), its translation on the next line.
  /// [skipped] stands for phrases that were not transcribed.
  static String text(
    List<TranscriptEntry> entries, {
    required String skipped,
    String? title,
  }) {
    final paragraphs = <String>[?title];
    for (final entry in entries) {
      final words = entry.hasText ? entry.text : skipped;
      final translated = entry.isTranslated && entry.translation.isNotEmpty;
      paragraphs.add(
        [
          '[${formatTranscriptTime(entry.start)}] $words',
          if (translated) entry.translation,
        ].join('\n'),
      );
    }
    return '${paragraphs.join('\n\n')}\n';
  }

  /// The transcribed text alone, a paragraph per phrase (for the history).
  static String plain(List<TranscriptEntry> entries) => [
    for (final entry in entries)
      if (entry.hasText) entry.text,
  ].join('\n\n');

  /// The translations alone, a paragraph per phrase (for the history).
  static String plainTranslation(List<TranscriptEntry> entries) => [
    for (final entry in entries)
      if (entry.hasText && entry.isTranslated) entry.translation,
  ].join('\n\n');

  /// SubRip subtitles: a numbered cue per transcribed phrase, from its
  /// start to its end, with the translation as a second line.
  static String srt(List<TranscriptEntry> entries) {
    final cues = <String>[];
    for (final entry in entries) {
      if (!entry.hasText) continue;
      final translated = entry.isTranslated && entry.translation.isNotEmpty;
      cues.add(
        [
          '${cues.length + 1}',
          '${srtTime(entry.start)} --> ${srtTime(entry.end)}',
          entry.text,
          if (translated) entry.translation,
        ].join('\n'),
      );
    }
    return cues.isEmpty ? '' : '${cues.join('\n\n')}\n';
  }

  /// `HH:MM:SS,mmm`.
  static String srtTime(Duration time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final ms = time.inMilliseconds < 0 ? 0 : time.inMilliseconds;
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:'
        '${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }

  /// [contents] as UTF-8 bytes for a file.
  static Uint8List bytes(String contents) => utf8.encode(contents);

  /// Whether some phrases were skipped or failed.
  static bool hasGaps(List<TranscriptEntry> entries) =>
      entries.any((entry) => entry.status != PhraseStatus.transcribed);
}
