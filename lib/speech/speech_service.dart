import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:mozhi/speech/audio_output.dart';
import 'package:translation_repository/translation_repository.dart';

export 'audio_output.dart';

/// Reads text aloud: fetches MP3 from Mozhi `/api/tts` (google, falling back
/// to reverso) through [TranslationRepository.textToSpeech] and plays it with
/// `audioplayers` (`BytesSource`; on platforms without byte playback it
/// writes a temp file / data URI). Caches the last 20 clips in memory.
/// [speaking] exposes the id of the clip currently playing (null = idle) so
/// buttons can show a stop icon.
///
/// `output` defaults to [AudioPlayersOutput]; the service owns it and
/// disposes it in [dispose]. The id is reported as speaking from the moment
/// [toggle] is called (including while the clip is being fetched) until the
/// clip completes, is stopped, or fails.
class SpeechService {
  new({required this._repository, AudioOutput? output})
    : _output = output ?? AudioPlayersOutput() {
    _completions = _output.onComplete.listen((_) => _onComplete());
  }

  /// Number of clips kept in the in-memory LRU cache.
  static const cacheSize = 20;

  final TranslationRepository _repository;
  final AudioOutput _output;
  final StreamController<String?> _speaking = StreamController.broadcast();
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  late final StreamSubscription<void> _completions;

  String? _current;

  /// Bumped by every [toggle]/[stop] so stale fetches/plays are ignored.
  int _generation = 0;

  /// Generation whose clip is currently playing, if any.
  int? _playing;

  /// Broadcast stream of the speaking id (null = idle); emits on change.
  Stream<String?> get speaking => _speaking.stream;
  String? get current => _current;

  /// Plays [text] in [languageCode]; [id] identifies the button (e.g.
  /// `source` / `target`). Calling with the id that is playing stops it.
  /// Throws on fetch failure (caller shows a snackbar).
  Future<void> toggle({
    required String id,
    required String text,
    required String languageCode,
  }) async {
    final trimmed = text.trim();
    if (_current == id || trimmed.isEmpty) {
      await stop();
      return;
    }

    final previous = _current;
    final generation = ++_generation;
    _playing = null;
    _setCurrent(id);
    try {
      if (previous != null) await _output.stop();
      final bytes = await _fetch(trimmed, languageCode);
      if (generation != _generation) return;
      await _output.play(bytes);
      if (generation != _generation) {
        // Stopped while starting: make sure nothing keeps playing.
        if (_current == null) await _output.stop();
        return;
      }
      _playing = generation;
    } on Object {
      if (generation != _generation) return;
      _setCurrent(null);
      rethrow;
    }
  }

  Future<void> stop() async {
    _generation++;
    _playing = null;
    _setCurrent(null);
    await _output.stop();
  }

  /// Stops playback and releases the audio output. The service cannot be
  /// used afterwards.
  Future<void> dispose() async {
    _generation++;
    _playing = null;
    _current = null;
    await _completions.cancel();
    await _speaking.close();
    await _output.dispose();
  }

  Future<Uint8List> _fetch(String text, String languageCode) async {
    final key = '$languageCode\u0000$text';
    final cached = _cache.remove(key);
    if (cached != null) return _cache[key] = cached;

    final bytes = await _repository.textToSpeech(
      text: text,
      languageCode: languageCode,
    );
    if (bytes.isEmpty) {
      throw const FormatException('Text-to-speech returned no audio');
    }
    _cache[key] = bytes;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return bytes;
  }

  void _onComplete() {
    if (_playing == null || _playing != _generation) return;
    _playing = null;
    _setCurrent(null);
  }

  void _setCurrent(String? id) {
    if (_current == id) return;
    _current = id;
    if (!_speaking.isClosed) _speaking.add(id);
  }
}
