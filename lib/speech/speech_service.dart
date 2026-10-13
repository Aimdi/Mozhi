import 'dart:async';

import 'package:translation_repository/translation_repository.dart';

/// Reads text aloud: fetches MP3 from Mozhi `/api/tts` (google, falling back
/// to reverso) through [TranslationRepository.textToSpeech] and plays it with
/// `audioplayers` (`BytesSource`; on platforms without byte playback it
/// writes a temp file / data URI). Caches the last 20 clips in memory.
/// [speaking] exposes the id of the clip currently playing (null = idle) so
/// buttons can show a stop icon.
class SpeechService {
  new();

  Stream<String?> get speaking => throw UnimplementedError();
  String? get current => throw UnimplementedError();

  /// Plays [text] in [languageCode]; [id] identifies the button (e.g.
  /// `source` / `target`). Calling with the id that is playing stops it.
  /// Throws on fetch failure (caller shows a snackbar).
  Future<void> toggle({
    required String id,
    required String text,
    required String languageCode,
  }) => throw UnimplementedError();

  Future<void> stop() => throw UnimplementedError();
  Future<void> dispose() => throw UnimplementedError();
}
