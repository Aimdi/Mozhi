import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// Plays encoded audio clips. Abstracts the audio plugin so `SpeechService`
/// can be unit tested.
abstract interface class AudioOutput {
  /// Starts playing [bytes] (an MP3 clip), replacing whatever is playing.
  /// Completes once playback has started; throws when the clip cannot be
  /// played.
  Future<void> play(Uint8List bytes);

  /// Stops playback. Does not emit [onComplete].
  Future<void> stop();

  /// Playback speed for this and later clips (1.0 = normal, 0.7 = slow).
  Future<void> setPlaybackRate(double rate);

  /// Emits each time a clip finishes playing on its own.
  Stream<void> get onComplete;

  /// Releases all resources; the output cannot be used afterwards.
  Future<void> dispose();
}

/// [AudioOutput] backed by `audioplayers`.
///
/// Plays a [BytesSource] (`audio/mpeg`); `audioplayers` itself bridges
/// platforms without native byte playback (temp file on iOS/macOS/Linux,
/// data URI on web). If the byte source is rejected anyway (e.g. Android
/// before 6.0), it retries with a `data:` URI [UrlSource].
///
/// The [AudioPlayer] is created lazily on first use, so constructing this
/// class never touches the platform plugin.
class AudioPlayersOutput implements AudioOutput {
  new({AudioPlayer Function()? createPlayer})
    : _createPlayer = createPlayer ?? AudioPlayer.new;

  static const mimeType = 'audio/mpeg';

  final AudioPlayer Function() _createPlayer;
  final StreamController<void> _completions = StreamController.broadcast();
  AudioPlayer? _player;
  StreamSubscription<void>? _playerCompletions;
  double _rate = 1;

  AudioPlayer get _activePlayer {
    if (_player case final player?) return player;
    final player = _player = _createPlayer();
    _playerCompletions = player.onPlayerComplete.listen(_completions.add);
    return player;
  }

  @override
  Stream<void> get onComplete => _completions.stream;

  @override
  Future<void> play(Uint8List bytes) async {
    final player = _activePlayer;
    try {
      await player.play(BytesSource(bytes, mimeType: mimeType));
    } on Object {
      final uri = Uri.dataFromBytes(bytes, mimeType: mimeType);
      await player.play(UrlSource(uri.toString(), mimeType: mimeType));
    }
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
  }

  /// Applies [rate] through `AudioPlayer.setPlaybackRate` (kept across
  /// clips). Skips the platform call when the rate is unchanged, so normal
  /// speed never creates the player.
  @override
  Future<void> setPlaybackRate(double rate) async {
    if (rate == _rate) return;
    await _activePlayer.setPlaybackRate(rate);
    _rate = rate;
  }

  @override
  Future<void> dispose() async {
    await _playerCompletions?.cancel();
    await _completions.close();
    await _player?.dispose();
    _player = null;
  }
}
