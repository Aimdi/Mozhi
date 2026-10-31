import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// How [CaptionsHost.start] ended.
sealed class CaptureStart extends Equatable {
  const new();

  @override
  List<Object?> get props => [];
}

/// The capture runs: [CaptionsHost.audio] delivers other apps' sound.
/// [captionBar]: the caption bar shows over other apps ("Display over
/// other apps" is allowed); without it the captions are only in the app.
final class CaptureStarted extends CaptureStart {
  const new({this.captionBar = true});

  final bool captionBar;

  @override
  List<Object?> get props => [captionBar];
}

/// The user turned the system's capture consent down.
final class CaptureDeclined extends CaptureStart {
  const new();
}

/// Nothing is captured: [reason] says why.
final class CaptureFailed extends CaptureStart {
  const new(this.reason);

  final CaptureFailure reason;

  @override
  List<Object?> get props => [reason];
}

/// Why [CaptionsHost.start] failed ([CaptureFailed]).
enum CaptureFailure {
  /// Not here: the web app, Android before 10.
  unsupported,

  /// The microphone permission (which capturing other apps' sound needs)
  /// was refused.
  permission,

  /// Another start or capture was in the way.
  busy,

  /// Android did not let the capture run in the foreground.
  foreground,

  /// The capture consent could not be used.
  projection,

  /// The device would not record other apps' sound.
  audio,

  /// Anything else (no window to ask in, the platform side went away).
  unknown;

  /// The failure named [code] by the platform; [unknown] for anything
  /// else.
  static CaptureFailure parse(String? code) => switch (code) {
    'unsupported' => unsupported,
    'permission' => permission,
    'busy' => busy,
    'foreground' => foreground,
    'projection' => projection,
    'audio' => audio,
    _ => unknown,
  };
}

/// What the caption bar shows ([CaptionsHost.show]): [translation] in
/// large text, [original] smaller below it (empty: none). [isFinal]: the
/// phrase is complete (a partial line is still being heard). A notice
/// ("Listening…", a pause) is a line with only a [translation].
final class CaptionLine extends Equatable {
  const new({this.original = '', this.translation = '', this.isFinal = true});

  /// A line that says [message] (no original).
  const new notice(String message) : this(translation: message);

  final String original;
  final String translation;
  final bool isFinal;

  @override
  List<Object?> get props => [original, translation, isFinal];
}

/// What happened outside the app while the captions run
/// ([CaptionsHost.events]).
enum CaptionBarEvent {
  /// Stop on the caption bar or in the notification: the capture has
  /// ended.
  stopTapped,

  /// Open on the caption bar: Mozhi came to the front.
  openTapped,

  /// The capture ended by itself: the projection was revoked (the status
  /// bar's stop), or the recording broke (also: it did not start again
  /// after the phone was unlocked).
  captureEnded,

  /// The phone was locked: nothing is recorded, so no audio arrives, until
  /// [deviceUnlocked].
  deviceLocked,

  /// The phone was unlocked again.
  deviceUnlocked;

  /// The event named [code] by the platform; null for anything else.
  static CaptionBarEvent? parse(Object? code) => switch (code) {
    'stopTapped' => stopTapped,
    'openTapped' => openTapped,
    'ended' => captureEnded,
    'locked' => deviceLocked,
    'unlocked' => deviceUnlocked,
    _ => null,
  };
}

/// The platform side of live captions: captures the sound other apps play
/// (Android 10+, `AudioPlaybackCaptureConfiguration` in
/// `LiveCaptionService.kt`) and shows the captions in a caption bar over
/// them. Nothing of the audio is stored: it only lives in [audio]'s
/// blocks.
abstract interface class CaptionsHost {
  /// Whether captions can run here (Android 10+).
  bool get isSupported;

  /// Asks for the microphone permission (when needed) and the system's
  /// capture consent (every time), then starts capturing.
  Future<CaptureStart> start();

  /// Mono 16 kHz samples (`-1..1`) of other apps' sound, in blocks of
  /// about 100 ms, while the capture runs.
  Stream<Float32List> get audio;

  /// Shows [line] in the caption bar (nothing without one).
  Future<void> show(CaptionLine line);

  /// Taps on the caption bar and the capture's end, lock and unlock.
  Stream<CaptionBarEvent> get events;

  /// Stops capturing and removes the caption bar.
  Future<void> stop();

  /// Whether [token] is the start request the Quick Settings tile made
  /// last (`LiveCaptionsTileService.kt`); true only once per token. A
  /// start request (`?start=<token>`) starts the captions only then: any
  /// other app can open the same link.
  Future<bool> consumeStartToken(String token);
}
