import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where live captions are (`LiveCaptionsCubit`).
enum LiveCaptionsStatus {
  /// Finding out whether captions can run here (the speech model).
  loading,

  /// Not here: the web app, Android before 10.
  unsupported,

  /// No speech model: the voice input settings offer one.
  needsModel,

  /// Ready to start (or stopped; the transcript stays).
  idle,

  /// Asking for the permissions and the capture consent.
  starting,

  /// Captioning.
  running,
}

/// Why running captions hear nothing for now.
enum LiveCaptionsPause {
  /// The phone is locked: no sound is captured until it is unlocked.
  locked,

  /// The phone is hot: the sound is not transcribed until it cools down.
  hot,
}

/// One-off messages for the screen (a snack bar), counted by
/// [LiveCaptionsState.notices].
enum LiveCaptionsNotice {
  /// The capture consent was turned down.
  declined,

  /// The microphone permission (needed to capture other apps' sound) was
  /// refused.
  permissionDenied,

  /// The capture could not start.
  startFailed,

  /// The capture ended by itself (revoked from the status bar, or the
  /// recording broke).
  captureEnded,

  /// Saved to History.
  saved,

  /// Saved to History as a favourite (history is paused).
  savedAsFavorite,

  /// Saving to History failed.
  saveFailed,
}

/// The state of `LiveCaptionsCubit`: whether captions run, the languages,
/// the transcript (in memory only) and what the screen should say.
@immutable
final class LiveCaptionsState extends Equatable {
  const new({
    required this.source,
    required this.target,
    this.status = LiveCaptionsStatus.loading,
    this.pause,
    this.entries = const [],
    this.detectedLanguage,
    this.captionBar = false,
    this.showOriginal = true,
    this.silenceHint = false,
    this.overlayPrompt = false,
    this.consent,
    this.notice,
    this.notices = 0,
    this.pending = 0,
  });

  /// The language of the sound; "Detect" ([Language.isAuto]) lets Whisper
  /// tell it phrase by phrase.
  final Language source;

  /// The language of the captions.
  final Language target;

  final LiveCaptionsStatus status;

  /// Why running captions hear nothing for now; null while they listen.
  final LiveCaptionsPause? pause;

  /// The transcript: a paragraph per phrase with its translation.
  final List<TranscriptEntry> entries;

  /// The app code of the language Whisper heard last ([source] Detect).
  final String? detectedLanguage;

  /// Whether the caption bar shows over other apps (else the captions are
  /// only on this screen).
  final bool captionBar;

  /// Whether the caption bar shows the original under the translation.
  final bool showOriginal;

  /// No sound for a while: the app playing may not allow capturing it.
  final bool silenceHint;

  /// The screen should explain "Display over other apps" before starting
  /// (`LiveCaptionsCubit.allowCaptionBar` / `skipCaptionBar`).
  final bool overlayPrompt;

  /// A translation waits for the user's consent to send text to its
  /// engine.
  final ConsentRequiredException? consent;

  /// The latest one-off message, and how many there were (a new one when
  /// it grows).
  final LiveCaptionsNotice? notice;
  final int notices;

  /// Phrases waiting for the speech engine.
  final int pending;

  bool get isRunning => status == LiveCaptionsStatus.running;

  /// Starting or running: the languages are fixed.
  bool get isActive => isRunning || status == LiveCaptionsStatus.starting;

  /// Whether captions can be started now.
  bool get canStart => status == LiveCaptionsStatus.idle;

  /// Whether there is something to save, copy or export.
  bool get hasTranscript => entries.any((entry) => entry.hasText);

  LiveCaptionsState copyWith({
    Language? source,
    Language? target,
    LiveCaptionsStatus? status,
    ValueGetter<LiveCaptionsPause?>? pause,
    List<TranscriptEntry>? entries,
    ValueGetter<String?>? detectedLanguage,
    bool? captionBar,
    bool? showOriginal,
    bool? silenceHint,
    bool? overlayPrompt,
    ValueGetter<ConsentRequiredException?>? consent,
    LiveCaptionsNotice? notice,
    int? notices,
    int? pending,
  }) => LiveCaptionsState(
    source: source ?? this.source,
    target: target ?? this.target,
    status: status ?? this.status,
    pause: pause != null ? pause() : this.pause,
    entries: entries ?? this.entries,
    detectedLanguage: detectedLanguage != null
        ? detectedLanguage()
        : this.detectedLanguage,
    captionBar: captionBar ?? this.captionBar,
    showOriginal: showOriginal ?? this.showOriginal,
    silenceHint: silenceHint ?? this.silenceHint,
    overlayPrompt: overlayPrompt ?? this.overlayPrompt,
    consent: consent != null ? consent() : this.consent,
    notice: notice ?? this.notice,
    notices: notices ?? this.notices,
    pending: pending ?? this.pending,
  );

  @override
  List<Object?> get props => [
    source,
    target,
    status,
    pause,
    entries,
    detectedLanguage,
    captionBar,
    showOriginal,
    silenceHint,
    overlayPrompt,
    consent,
    notice,
    notices,
    pending,
  ];
}
